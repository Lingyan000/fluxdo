import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// 只从 Google 官方发布物提取 CPU 库。构建时下载，用户设备不下载可执行代码。
const _version = '2.4.0';
const _release =
    'https://github.com/google-ai-edge/LiteRT/releases/download/v$_version';
const _pypi = 'https://files.pythonhosted.org/packages';
typedef _ArchiveSource = ({String url, String sha});

const _android = (
  url:
      'https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/$_version/litert-$_version.aar',
  sha: '13926c98f35417b6fe4f104f780ab869747b4a69f08a91ccd224013c6bf71615',
);
const _ios = (
  url: '$_release/TensorFlowLiteC.xcframework.zip',
  sha: '945a2b5d5ef9eea51f3d06d9ebe9087db4c31edcd36195de542465db8039db6a',
);
const _macos = (
  url: '$_release/CLiteRT_mac.xcframework.zip',
  sha: '5a5f235fd3ad1477d81a223df50699058773446f46aa06236fdf7ce89f6ecea9',
);

_ArchiveSource _source(OS os, Architecture arch) => switch ((os, arch)) {
  (OS.android, _) => _android,
  (OS.iOS, Architecture.arm64) => _ios,
  (OS.macOS, Architecture.arm64 || Architecture.x64) => _macos,
  (OS.linux, Architecture.x64) => (
    url:
        '$_pypi/4b/a9/87d838fbc6f9e4059158b92d3e6e355838af8ca14938d872c6b4d94b352b/ai_edge_litert-$_version-cp312-cp312-manylinux_2_27_x86_64.whl',
    sha: '1ad7b17c7fd0267db96a58d48ae09c7a39738c181a3f23c414b5cb0555f9ee47',
  ),
  (OS.linux, Architecture.arm64) => (
    url:
        '$_pypi/03/7e/3887c67fa5235373f22fbe6ebf5378a68c3d6547441776b5654e8f8dff21/ai_edge_litert-$_version-cp312-cp312-manylinux_2_27_aarch64.whl',
    sha: '575ff9fdd7fcdda0fe8b79f26bcc08dca2b98395d41d1b59771f87eda01bc6f0',
  ),
  (OS.windows, Architecture.x64) => (
    url:
        '$_pypi/f8/2b/aa32ea0d84b5c1f03013ea8558a45c6759bef80150276e685942eb07f08b/ai_edge_litert-$_version-cp312-cp312-win_amd64.whl',
    sha: 'c96479e4fd791976e68d1985db655e293e6e5492a19e1863ed0c9a2223287acc',
  ),
  (OS.windows, Architecture.arm64) => (
    url:
        '$_pypi/b7/a1/acdc92410e0a3b51b9a88e46fc49b28e1e7d87f2211d7f5b436444e40413/ai_edge_litert-$_version-cp312-cp312-win_arm64.whl',
    sha: 'd26b9b68e82a0b18c6003dc6ce0ac39e243c34bf06bdcdc33cf85fd8de6ea8a1',
  ),
  _ => throw UnsupportedError('LiteRT $_version 没有 $os $arch 的官方 CPU 库'),
};

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final os = code.targetOS;
  final arch = code.targetArchitecture;
  final archive = await _runtimeArchive(input, _source(os, arch));
  if (archive.uri.path.startsWith(input.packageRoot.path)) {
    output.dependencies.add(archive.uri);
  }
  final zip = InputFileStream(archive.path);
  late final Uri library;
  try {
    final files = ZipDecoder().decodeStream(zip);
    final member = switch (os) {
      OS.android => 'jni/${_androidAbi(arch)}/libLiteRt.so',
      OS.linux => 'ai_edge_litert/libLiteRt.so',
      OS.windows => 'ai_edge_litert/libLiteRt.dll',
      OS.macOS =>
        'CLiteRT_mac.xcframework/macos-arm64_x86_64/libCLiteRT_mac.dylib',
      OS.iOS =>
        'TensorFlowLiteC.xcframework/'
            '${code.iOS.targetSdk == IOSSdk.iPhoneOS ? 'ios-arm64' : 'ios-arm64-simulator'}/'
            'TensorFlowLiteC.framework/TensorFlowLiteC',
      _ => throw UnsupportedError('OCR 不支持 $os'),
    };
    library = input.outputDirectory.resolve(
      os == OS.iOS ? 'libTensorFlowLiteC.a' : member.split('/').last,
    );
    if (os == OS.macOS) {
      // macOS xcframework 分发的是 arm64+x86_64 通用二进制，hooks 校验要求按目标架构拆成单架构 Mach-O。
      final universal = input.outputDirectory.resolve(
        'libCLiteRT_mac.universal.dylib',
      );
      _extract(files, member, universal);
      try {
        await _thinMachO(universal, library, arch);
      } finally {
        final f = File.fromUri(universal);
        if (await f.exists()) await f.delete();
      }
    } else {
      _extract(files, member, library);
    }
  } finally {
    zip.closeSync();
  }
  if (os == OS.iOS) {
    // 静态框架链接到随包桥库，导出的 C API 仍通过同一个资产 ID 解析。
    await CBuilder.library(
      name: 'fluxdo_litert',
      assetName: 'litert',
      sources: ['src/ios_runtime.c'],
      flags: ['-Xlinker', '-force_load', '-Xlinker', library.toFilePath()],
      libraries: ['c++'],
      frameworks: ['Foundation', 'CoreFoundation'],
    ).run(input: input, output: output);
  } else {
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'litert',
        file: library,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  }

  // 全 5 端编译原生 C 图像预处理、DB 连通域提取、CTC 解码与 line2para 段落归并算子库（默认 O3 优化）。
  await CBuilder.library(
    name: 'fluxdo_ocr_ops',
    assetName: 'ocr_ops',
    sources: ['src/ocr_ops.c', 'src/line2para.c'],
    libraries: os == OS.linux || os == OS.android ? ['m'] : const [],
  ).run(input: input, output: output);
});

String _androidAbi(Architecture arch) => switch (arch) {
  Architecture.arm => 'armeabi-v7a',
  Architecture.arm64 => 'arm64-v8a',
  Architecture.x64 => 'x86_64',
  _ => throw UnsupportedError('LiteRT $_version 没有 Android $arch 的官方 CPU 库'),
};

Future<void> _thinMachO(
  Uri universal,
  Uri destination,
  Architecture arch,
) async {
  final slice = switch (arch) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    _ => throw UnsupportedError('LiteRT $_version 没有 macOS $arch 的官方 CPU 库'),
  };
  final result = await Process.run('lipo', [
    '-thin',
    slice,
    universal.toFilePath(),
    '-output',
    destination.toFilePath(),
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'lipo',
      ['-thin', slice, universal.toFilePath(), '-output', destination.toFilePath()],
      '${result.stderr}',
      result.exitCode,
    );
  }
}

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

Future<File> _runtimeArchive(BuildInput input, _ArchiveSource source) async {
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
