import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// 1.19.2 的 Apple 库兼容 iOS 13 / macOS 11。Android 的 AAR 支持 16 KiB 内存页。
const _desktop = (
  url: 'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.19.2/microsoft.ml.onnxruntime.1.19.2.nupkg',
  sha: 'fa133c8fe6238445a0dd3e8447baa5c7d16f418caa8e576c7e253ba77b27b61b',
);
const _android = (
  url: 'https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.22.0/onnxruntime-android-1.22.0.aar',
  sha: '04a4617a9c797cf49225595e45b5546081cb34c86ac817581141577d3b7dbfe2',
);

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final os = code.targetOS;
  final arch = code.targetArchitecture;
  final dir = input.outputDirectory;
  final source = os == OS.android ? _android : _desktop;
  final archive = await _runtimeArchive(input, source);
  if (archive.uri.path.startsWith(input.packageRoot.path)) {
    output.dependencies.add(archive.uri);
  }
  final zip = InputFileStream(archive.path);
  String? iosLibrary;
  try {
    final files = ZipDecoder().decodeStream(zip);
    _extract(
      files,
      os == OS.android
          ? 'headers/onnxruntime_c_api.h'
          : 'build/native/include/onnxruntime_c_api.h',
      dir.resolve('onnxruntime_c_api.h'),
    );
    if (os == OS.iOS) {
      final framework = dir.resolve('onnxruntime.xcframework.zip');
      _extract(
        files,
        'runtimes/ios/native/onnxruntime.xcframework.zip',
        framework,
      );
      final slice = code.iOS.targetSdk == IOSSdk.iPhoneOS
          ? 'ios-arm64'
          : 'ios-arm64_x86_64-simulator';
      final inner = InputFileStream(framework.toFilePath());
      try {
        final library = dir.resolve('libonnxruntime.a');
        _extract(
          ZipDecoder().decodeStream(inner),
          'onnxruntime.xcframework/$slice/onnxruntime.framework/onnxruntime',
          library,
        );
        iosLibrary = library.toFilePath();
      } finally {
        inner.closeSync();
        File.fromUri(framework).deleteSync();
      }
    } else {
      final member = switch (os) {
        OS.android => 'jni/${_androidAbi(arch)}/libonnxruntime.so',
        OS.linux => 'runtimes/linux-${arch.name}/native/libonnxruntime.so',
        OS.macOS => 'runtimes/osx-${arch.name}/native/libonnxruntime.dylib',
        OS.windows =>
          'runtimes/win-${arch == Architecture.ia32 ? 'x86' : arch.name}/native/onnxruntime.dll',
        _ => throw UnsupportedError('OCR 不支持 $os'),
      };
      final library = dir.resolve(member.split('/').last);
      _extract(files, member, library);
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'onnxruntime',
          file: library,
          linkMode: DynamicLoadingBundled(),
        ),
      );
    }
  } finally {
    zip.closeSync();
  }
  // 头文件来自已固定摘要的发布包。把生成目录作为 includes 会让编译器
  // 把刚生成的动态库也登记为输入，导致每次启动都要重新编译。
  final headerDirectory = File.fromUri(dir.resolve('onnxruntime_c_api.h'))
      .parent
      .path;
  await CBuilder.library(
    name: 'fluxdo_ocr',
    assetName: 'bridge',
    sources: ['src/ocr.c'],
    defines: {if (iosLibrary != null) 'FLUX_OCR_STATIC': null},
    flags: [
      if (os == OS.windows) ...[
        '/utf-8',
        '/I$headerDirectory',
      ] else
        '-I$headerDirectory',
      if (iosLibrary != null) ...[
        '-Xlinker',
        '-force_load',
        '-Xlinker',
        iosLibrary,
      ],
    ],
    libraries: [if (iosLibrary != null) 'c++'],
    frameworks: [
      if (iosLibrary != null) ...['Foundation', 'CoreML'],
    ],
  ).run(input: input, output: output);
});

String _androidAbi(Architecture arch) => switch (arch) {
  Architecture.arm => 'armeabi-v7a',
  Architecture.arm64 => 'arm64-v8a',
  Architecture.x64 => 'x86_64',
  Architecture.ia32 => 'x86',
  _ => throw UnsupportedError('OCR 不支持 Android $arch'),
};

void _extract(Archive files, String member, Uri destination) {
  final file = files.findFile(member);
  if (file == null || !file.isFile) throw FormatException('运行库缺少 $member');
  final sink = OutputFileStream(destination.toFilePath());
  try {
    file.writeContent(sink);
  } finally {
    sink.closeSync();
  }
}

Future<File> _runtimeArchive(
  BuildInput input,
  ({String url, String sha}) source,
) async {
  final uri = Uri.parse(source.url);
  final name = uri.pathSegments.last;
  final staged = File.fromUri(
    input.packageRoot.resolve('.dart_tool/runtime/$name'),
  );
  final cache = File.fromUri(input.outputDirectoryShared.resolve(name));
  final file = await staged.exists() ? staged : cache;
  Future<bool> valid(File f) async =>
      await f.exists() &&
      (await sha256.bind(f.openRead()).first).toString() == source.sha;
  if (await valid(file)) return file;
  if (file == staged) throw FormatException('离线运行库校验失败 $name');

  await cache.parent.create(recursive: true);
  // 多个目标架构可能同时构建，只发布完整且经过校验的压缩包。
  final temp = File('${cache.path}.$pid.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    await response.timeout(const Duration(seconds: 90)).pipe(temp.openWrite());
    if (!await valid(temp)) throw FormatException('运行库校验失败 $name');
    try {
      await temp.rename(cache.path);
    } on FileSystemException {
      if (!await valid(cache)) rethrow;
    }
    return cache;
  } finally {
    client.close(force: true);
    if (await temp.exists()) await temp.delete();
  }
}
