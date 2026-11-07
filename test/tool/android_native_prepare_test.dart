import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final projectRoot = Directory.current;
  final flutterPackage =
      ((jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
                  as Map)['packages']
              as List)
          .cast<Map>()
          .firstWhere((package) => package['name'] == 'flutter');
  final flutterUri = File('.dart_tool/package_config.json').absolute.uri
      .resolve('${flutterPackage['rootUri']}/');
  final dartExecutable = File.fromUri(
    flutterUri.resolve(
      '../../bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
    ),
  ).path;

  late Directory workspace;
  late Directory ndk;
  late File callsFile;
  late Map<String, String> environment;
  late Directory probeWorkspace;
  late File probeExecutable;
  String? hostLibclang;
  final executableSuffix = Platform.isWindows ? '.exe' : '';
  final ndkHost = Platform.isWindows
      ? 'windows-x86_64'
      : Platform.isMacOS
      ? 'darwin-x86_64'
      : 'linux-x86_64';

  setUpAll(() async {
    // 用实际可执行文件模拟工具，覆盖 Windows .exe 路径及退出码。
    probeWorkspace = await Directory.systemTemp.createTemp(
      'fluxdo_native_probes_',
    );
    final probe = File('${probeWorkspace.path}/probe.dart')
      ..writeAsStringSync(r'''
import 'dart:io';
void main(List<String> args) {
  final tool = File(Platform.resolvedExecutable).uri.pathSegments.last.replaceAll('.exe', '');
  File(Platform.environment['FLUXDO_TEST_PROBES']!).writeAsStringSync('$tool\n', mode: FileMode.append);
  final missing = (Platform.environment['FLUXDO_TEST_MISSING'] ?? '').split(',');
  if (missing.contains(tool)) exit(1);
  if (tool == 'rustup') {
    stdout.writeln(Platform.environment['FLUXDO_TEST_TARGETS'] ?? 'aarch64-linux-android');
  } else if (tool == 'cmake') {
    stdout.writeln('cmake version ${Platform.environment['FLUXDO_TEST_CMAKE_VERSION'] ?? '3.22.1'}');
  } else if (tool == 'clang' && args.contains('-print-resource-dir')) {
    stdout.writeln(Platform.environment['FLUXDO_TEST_RESOURCE_DIR']);
  } else {
    stdout.writeln('$tool 1.0.0');
  }
}
''');
    probeExecutable = File('${probeWorkspace.path}/probe$executableSuffix');
    final compile = await Process.run(dartExecutable, [
      'compile',
      'exe',
      probe.path,
      '-o',
      probeExecutable.path,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final doctor = await Process.run(
      dartExecutable,
      [
        'tool/project_tasks.dart',
        'native:doctor',
        '--target-platform=android-arm64',
      ],
      workingDirectory: projectRoot.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    hostLibclang = RegExp(r'\[OK\] libclang（(.+)）')
        .firstMatch(doctor.stdout as String)
        ?.group(1);
  });

  tearDownAll(() async {
    await probeWorkspace.delete(recursive: true);
  });

  Future<void> writeLauncher(String path, String body) async {
    final file = File(path)..writeAsStringSync(body);
    if (!Platform.isWindows) {
      expect((await Process.run('chmod', ['+x', file.path])).exitCode, 0);
    }
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'fluxdo_android_prep_test_',
    );
    for (final path in [
      'tool',
      'android',
      'core/net_core',
      'bin',
      'sdk/cmake/3.22.1/bin',
    ]) {
      Directory('${workspace.path}/$path').createSync(recursive: true);
    }
    ndk = Directory('${workspace.path}/sdk/ndk/28.2.13676358')
      ..createSync(recursive: true);
    for (final name in ['project_tasks.dart', '_workspace_cli.dart']) {
      File('${projectRoot.path}/tool/$name')
          .copySync('${workspace.path}/tool/$name');
    }
    File('${workspace.path}/tool/project_prep.dart')
        .writeAsStringSync('void main() {}');
    File('${workspace.path}/android/local.properties').writeAsStringSync(
      'sdk.dir=${workspace.path.replaceAll('\\', '/')}/sdk\n',
    );
    File('${workspace.path}/bin/cargo.dart').writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  if (!args.contains('build')) {
    final tool = args.contains('ndk') ? 'cargo-ndk' : 'cargo';
    if ((Platform.environment['FLUXDO_TEST_MISSING'] ?? '').split(',').contains(tool)) exit(1);
    stdout.writeln('$tool 1.0.0');
    return;
  }
  File(Platform.environment['FLUXDO_TEST_CALLS']!).writeAsStringSync(
    jsonEncode({'args': args, 'environment': Platform.environment}) + '\n',
    mode: FileMode.append,
  );
  final output = File('target/aarch64-linux-android/release/libfluxdo_net.so');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync('test native library');
}
''');
    await writeLauncher(
      '${workspace.path}/bin/${Platform.isWindows ? 'cargo.cmd' : 'cargo'}',
      Platform.isWindows ? '@"%FLUXDO_TEST_DART%" "%~dp0cargo.dart" %*\r\n' : '#!/bin/sh\nexec "\$FLUXDO_TEST_DART" "\$(dirname "\$0")/cargo.dart" "\$@"\n',
    );
    final cmakeBin = '${workspace.path}/sdk/cmake/3.22.1/bin';
    for (final tool in ['cmake', 'ninja']) {
      probeExecutable.copySync('$cmakeBin/$tool$executableSuffix');
    }
    for (final tool in ['git', 'rustup', 'make']) {
      probeExecutable.copySync('${workspace.path}/bin/$tool$executableSuffix');
    }
    final ndkBin = Directory(
      '${ndk.path}/toolchains/llvm/prebuilt/$ndkHost/bin',
    )..createSync(recursive: true);
    for (final compiler in ['clang', 'clang++']) {
      probeExecutable.copySync('${ndkBin.path}/$compiler$executableSuffix');
    }
    final toolchain = File('${ndk.path}/build/cmake/android.toolchain.cmake');
    toolchain.parent.createSync(recursive: true);
    toolchain.writeAsStringSync('');
    final header = File('${workspace.path}/clang-resource/include/stddef.h');
    header.parent.createSync(recursive: true);
    header.writeAsStringSync('');
    callsFile = File('${workspace.path}/cargo-calls.jsonl');
    environment = Map.of(Platform.environment);
    final pathKey = environment.keys.firstWhere(
      (key) => key.toUpperCase() == 'PATH',
    );
    environment[pathKey] =
        '${workspace.path}/bin${Platform.isWindows ? ';' : ':'}${environment[pathKey]}';
    environment.addAll({
      'ANDROID_NDK_HOME': '',
      'ANDROID_NDK_ROOT': '',
      'CMAKE_GENERATOR': '',
      'CMAKE': '$cmakeBin/cmake$executableSuffix',
      'LIBCLANG_PATH': hostLibclang ?? '${workspace.path}/missing-libclang',
      'FLUXDO_TEST_DART': dartExecutable,
      'FLUXDO_TEST_CALLS': callsFile.path,
      'FLUXDO_TEST_PROBES': '${workspace.path}/probes.txt',
      'FLUXDO_TEST_RESOURCE_DIR': header.parent.parent.path,
      'DART_SUPPRESS_ANALYTICS': 'true',
    });
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  Future<ProcessResult> prepare() => Process.run(
    dartExecutable,
    [
      '${workspace.path}/tool/project_tasks.dart',
      'native:prepare',
      'android',
      '--profile',
      '--target-platform=android-arm64',
    ],
    workingDirectory: workspace.path,
    environment: environment,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  test('passes the discovered NDK and SDK build tools to Cargo, then reuses the core', () async {
    if (hostLibclang == null) {
      markTestSkipped('成功构建分支需要宿主机安装 libclang');
      return;
    }
    final first = await prepare();
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    final call = jsonDecode(callsFile.readAsLinesSync().single) as Map;
    final cargoEnvironment = call['environment'] as Map;
    expect(
      Directory(cargoEnvironment['ANDROID_NDK_HOME'] as String)
          .resolveSymbolicLinksSync(),
      ndk.resolveSymbolicLinksSync(),
    );
    expect(
      cargoEnvironment['ANDROID_NDK_ROOT'],
      cargoEnvironment['ANDROID_NDK_HOME'],
    );
    final path =
        cargoEnvironment.entries
                .firstWhere(
                  (entry) => (entry.key as String).toUpperCase() == 'PATH',
                )
                .value
            as String;
    expect(path.replaceAll('\\', '/'), contains('/sdk/cmake/3.22.1/bin'));
    if (Platform.isWindows) {
      expect(cargoEnvironment['CMAKE_GENERATOR'], 'Ninja');
    }
    expect((call['args'] as List).take(8).toList(), [
      'ndk',
      '-t',
      'arm64-v8a',
      '--platform',
      '28',
      'build',
      '--release',
      '--lib',
    ]);
    if (Platform.isWindows) {
      final args = (call['args'] as List).cast<String>();
      final compilerPath =
          '${ndk.resolveSymbolicLinksSync().replaceAll('\\', '/')}'
          '/toolchains/llvm/prebuilt/windows-x86_64/bin';
      expect(
        args,
        contains(
          'env.CLANG_PATH.value=${jsonEncode('$compilerPath/clang.exe')}',
        ),
      );
      expect(args, contains('env.CLANG_PATH.force=true'));
      expect(
        args,
        contains(
          'env.CC_aarch64-linux-android.value=${jsonEncode('$compilerPath/clang.exe')}',
        ),
      );
      expect(
        args,
        contains(
          'env.CXX_aarch64-linux-android.value=${jsonEncode('$compilerPath/clang++.exe')}',
        ),
      );
      expect(args, contains('env.CC_aarch64-linux-android.force=true'));
      expect(args, contains('env.CXX_aarch64-linux-android.force=true'));
    }
    expect(
      File(
        '${workspace.path}/android/app/src/main/jniLibs/arm64-v8a/libfluxdo_net.so',
      ).readAsStringSync(),
      'test native library',
    );

    final probes = File(environment['FLUXDO_TEST_PROBES']!);
    final initialProbes = probes.readAsStringSync();
    environment['FLUXDO_TEST_MISSING'] =
        'cargo,cargo-ndk,git,rustup,cmake,ninja,clang,clang++';
    environment['LIBCLANG_PATH'] = '${workspace.path}/missing-libclang';
    final second = await prepare();
    expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
    expect(callsFile.readAsLinesSync(), hasLength(1));
    expect(probes.readAsStringSync(), initialProbes);
    expect(second.stdout, contains('Android 网络核心产物已是最新状态'));
  });

  test('preserves an explicit NDK and CMake generator', () async {
    if (hostLibclang == null) {
      markTestSkipped('成功构建分支需要宿主机安装 libclang');
      return;
    }
    environment['ANDROID_NDK_HOME'] = ndk.path;
    environment['CMAKE_GENERATOR'] = 'Unix Makefiles';
    final result = await prepare();
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final cargoEnvironment =
        (jsonDecode(callsFile.readAsLinesSync().single) as Map)['environment']
            as Map;
    expect(
      cargoEnvironment['ANDROID_NDK_HOME'],
      ndk.resolveSymbolicLinksSync().replaceAll('\\', '/'),
    );
    expect(
      cargoEnvironment['ANDROID_NDK_ROOT'],
      cargoEnvironment['ANDROID_NDK_HOME'],
    );
    expect(cargoEnvironment['CMAKE_GENERATOR'], 'Unix Makefiles');
  });

  test('reports missing tools together and stops before building', () async {
    environment['FLUXDO_TEST_MISSING'] = 'cargo-ndk,ninja';
    environment['FLUXDO_TEST_TARGETS'] = 'x86_64-pc-windows-msvc';
    environment['FLUXDO_TEST_CMAKE_VERSION'] = '3.18.0';
    environment['LIBCLANG_PATH'] = '${workspace.path}/missing-libclang';
    environment['CMAKE_GENERATOR'] = 'Ninja';
    final result = await prepare();
    expect(result.exitCode, 1);
    for (final message in [
      'cargo install cargo-ndk',
      'rustup target add aarch64-linux-android',
      'CMake',
      'Ninja',
      'libclang',
      'LIBCLANG_PATH',
    ]) {
      expect(result.stderr, contains(message));
    }
    expect(callsFile.existsSync(), isFalse);
  });

  test(
    'rejects an invalid libclang file and incomplete NDK before building',
    () async {
      final fakeLibrary = File('${workspace.path}/libclang.dll')
        ..writeAsStringSync('invalid');
      environment['LIBCLANG_PATH'] = fakeLibrary.path;
      File('${ndk.path}/build/cmake/android.toolchain.cmake').deleteSync();
      File('${workspace.path}/clang-resource/include/stddef.h').deleteSync();
      final result = await prepare();
      expect(result.exitCode, 1);
      expect(result.stderr, contains('libclang'));
      expect(result.stderr, contains('android.toolchain.cmake'));
      expect(result.stderr, contains('stddef.h'));
      expect(callsFile.existsSync(), isFalse);
    },
  );

  test(
    'doctor uses the same checks without building or writing a stage stamp',
    () async {
      environment['FLUXDO_TEST_MISSING'] = 'cargo-ndk';
      environment['LIBCLANG_PATH'] = '${workspace.path}/missing-libclang';
      final result = await Process.run(
        dartExecutable,
        [
          '${workspace.path}/tool/project_tasks.dart',
          'native:doctor',
          '--target-platform=android-arm64',
        ],
        workingDirectory: workspace.path,
        environment: environment,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, 1);
      expect(result.stderr, contains('cargo install cargo-ndk'));
      expect(result.stderr, contains('libclang'));
      expect(callsFile.existsSync(), isFalse);
      expect(
        File('${workspace.path}/.dart_tool/fluxdo_tooling/native/android.stamp')
            .existsSync(),
        isFalse,
      );
    },
  );
}
