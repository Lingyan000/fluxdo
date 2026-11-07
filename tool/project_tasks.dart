import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '_workspace_cli.dart';

enum _BuildMode { debug, release }

Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  if (args.isEmpty) {
    stderr.writeln(_usage);
    exit(64);
  }

  switch (args.first) {
    case 'app:clean':
      await _appClean();
      return;
    case 'app:rebuild':
      await _appRebuild(args.sublist(1));
      return;
    case 'test:all':
      await _testAll(args.sublist(1));
      return;
    case 'run:prepare':
      await _runPrepare(args.sublist(1));
      return;
    case 'native:prepare':
      await _nativePrepare(args.sublist(1));
      return;
    case 'native:doctor':
      final targets = _resolveAndroidTargets(_parseTargetPlatforms(args));
      await _checkedAndroidNativeEnvironment(targets);
      return;
    case 'release:prepare':
      await _releasePrepare(args.sublist(1));
      return;
    case 'help':
    case '--help':
    case '-h':
      stdout.writeln(_usage);
      return;
    default:
      stderr.writeln('未知项目任务: ${args.first}');
      stderr.writeln(_usage);
      exit(64);
  }
}

Future<void> _appClean() async {
  await runFlutterOrExit(title: '执行 flutter clean', arguments: const ['clean']);
  resetPubGetStamp();
}

Future<void> _appRebuild(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart tool/project_tasks.dart app:rebuild <flutter build args...>',
    );
    exit(64);
  }

  await _appClean();
  await runOrExit(
    title: '执行 flutter build ${args.join(' ')}',
    executable: Platform.resolvedExecutable,
    arguments: ['tool/flutterw.dart', 'build', ...args],
  );
}

Future<void> _testAll(
  List<String> args, {
  bool includePrep = true,
}) async {
  if (includePrep) {
    await _runProjectPrep('test');
  }

  final testTasks = _buildWorkspaceTestTasks(args);
  for (final task in testTasks) {
    await runFlutterOrExit(
      title: '执行 ${task.label} flutter test',
      arguments: task.arguments,
      workingDirectory: task.workingDirectory,
    );
  }
}

Future<void> _nativePrepare(List<String> args) async {
  final target = _parseNativeTarget(args);
  final mode = _parseBuildMode(args);
  final androidTargets = _parseTargetPlatforms(args);
  final macOsArch = _parseMacOsArch(args);

  switch (target) {
    case 'certs':
      await _runProjectPrep('certs');
      return;
    case 'auto':
      await _prepareAutoNative(mode, androidTargets);
      return;
    case 'desktop':
      await _prepareDesktopHost(mode, arch: macOsArch);
      return;
    case 'windows':
      await _prepareWindowsNative(mode);
      return;
    case 'macos':
      await _prepareMacOsNative(mode, arch: macOsArch);
      return;
    case 'linux':
      await _prepareLinuxNative(mode);
      return;
    case 'android':
      await _runProjectPrep('certs');
      await _prepareAndroidNative(mode, androidTargets);
      return;
    case 'ios':
      await _prepareIosNative(mode);
      return;
    case 'all':
      await _runProjectPrep('certs');
      if (Platform.isWindows) {
        await _prepareWindowsNative(mode);
        await _prepareAndroidNative(mode, androidTargets);
      } else if (Platform.isMacOS) {
        await _prepareMacOsNative(mode, arch: macOsArch);
        await _prepareAndroidNative(mode, androidTargets);
        await _prepareIosNative(mode);
      } else if (Platform.isLinux) {
        await _prepareLinuxNative(mode);
        await _prepareAndroidNative(mode, androidTargets);
      } else {
        stderr.writeln('当前平台不支持 native:prepare all');
        exit(64);
      }
      return;
    default:
      stderr.writeln('未知 native:prepare 目标: $target');
      stderr.writeln(_usage);
      exit(64);
  }
}

Future<void> _runPrepare(List<String> args) async {
  final mode = _parseBuildMode(args);
  final androidTargets = _parseTargetPlatforms(args);

  await _runProjectPrep('app');
  await _prepareAutoNative(mode, androidTargets);
}

Future<void> _prepareAutoNative(
  _BuildMode mode,
  List<String>? requestedAndroidTargets,
) async {
  stdout.writeln('==> 按宿主机与当前已连接设备自动准备原生产物');

  final devices = await _loadFlutterDevices();
  final androidTargets =
      requestedAndroidTargets == null || requestedAndroidTargets.isEmpty
      ? _connectedAndroidTargetPlatforms(devices)
      : requestedAndroidTargets;

  if (Platform.isWindows) {
    await _runAutoPrepareStep(
      label: 'Windows 原生产物',
      check: () => _checkDesktopAutoPrepare('windows', mode),
      action: () => _prepareWindowsNative(mode),
    );
    await _prepareAndroidAuto(mode, androidTargets);
    return;
  }

  if (Platform.isMacOS) {
    await _runAutoPrepareStep(
      label: 'macOS 原生产物',
      check: () => _checkDesktopAutoPrepare('macos', mode),
      action: () => _prepareMacOsNative(mode),
    );
    await _prepareAndroidAuto(mode, androidTargets);
    await _prepareIosAuto(mode, devices);
    return;
  }

  if (Platform.isLinux) {
    await _runAutoPrepareStep(
      label: 'Linux 原生产物',
      check: () => _checkDesktopAutoPrepare('linux', mode),
      action: () => _prepareLinuxNative(mode),
    );
    await _prepareAndroidAuto(mode, androidTargets);
    return;
  }

  stderr.writeln('当前平台不支持 native:prepare auto');
  exit(64);
}

Future<void> _releasePrepare(List<String> args) async {
  final strictAnalyze = args.contains('--strict-analyze');
  final skipAnalyze = args.contains('--skip-analyze');
  final skipTest = args.contains('--skip-test');

  await _runProjectPrep('app');

  if (!skipAnalyze) {
    await runFlutterOrExit(
      title: strictAnalyze ? '执行 flutter analyze' : '执行 flutter analyze（非严格模式）',
      arguments: [
        'analyze',
        if (!strictAnalyze) ...const [
          '--no-fatal-infos',
          '--no-fatal-warnings',
        ],
      ],
    );
  }

  if (!skipTest) {
    await _testAll(const [], includePrep: false);
  }
}

List<_FlutterTestTask> _buildWorkspaceTestTasks(List<String> args) {
  final testPackages = _workspaceTestPackages();
  final targetPackages = <String, List<String>>{};
  final passthroughArgs = <String>[];

  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (_flutterTestOptionConsumesNextValue(arg)) {
      passthroughArgs.add(arg);
      if (index + 1 < args.length) {
        passthroughArgs.add(args[index + 1]);
        index++;
      }
      continue;
    }

    final resolvedTarget = _resolveExplicitTestTarget(arg, testPackages);
    if (resolvedTarget == null) {
      passthroughArgs.add(arg);
      continue;
    }

    targetPackages.putIfAbsent(resolvedTarget.packagePath, () => <String>[]).add(
      resolvedTarget.relativeTarget,
    );
  }

  if (targetPackages.isEmpty) {
    return testPackages
        .map(
          (testPackage) => _FlutterTestTask(
            label: testPackage.label,
            arguments: ['test', ...passthroughArgs],
            workingDirectory: testPackage.workingDirectory,
          ),
        )
        .toList(growable: false);
  }

  return testPackages
      .where((testPackage) => targetPackages.containsKey(testPackage.packagePath))
      .map(
        (testPackage) => _FlutterTestTask(
          label: testPackage.label,
          arguments: [
            'test',
            ...passthroughArgs,
            ...targetPackages[testPackage.packagePath]!,
          ],
          workingDirectory: testPackage.workingDirectory,
        ),
      )
      .toList(growable: false);
}

List<_WorkspaceTestPackage> _workspaceTestPackages() {
  final packages = <_WorkspaceTestPackage>[];

  if (Directory('test').existsSync()) {
    packages.add(
      const _WorkspaceTestPackage(
        label: '主应用',
        packagePath: '.',
        workingDirectory: null,
      ),
    );
  }

  final packagesRoot = Directory('packages');
  if (packagesRoot.existsSync()) {
    final packageDirs =
        packagesRoot
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where((directory) => Directory('${directory.path}/test').existsSync())
            .toList(growable: false)
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final directory in packageDirs) {
      packages.add(
        _WorkspaceTestPackage(
          label: _packageNameFromPath(directory.path),
          packagePath: directory.path,
          workingDirectory: directory.path,
        ),
      );
    }
  }

  return packages;
}

_ExplicitTestTarget? _resolveExplicitTestTarget(
  String arg,
  List<_WorkspaceTestPackage> testPackages,
) {
  if (arg.startsWith('-')) {
    return null;
  }

  final entityType = FileSystemEntity.typeSync(arg, followLinks: true);
  if (entityType == FileSystemEntityType.notFound) {
    return null;
  }

  final absolutePath = _normalizeTestPath(File(arg).absolute.path);
  for (final testPackage in testPackages) {
    final packageRootPath = _normalizeTestPath(
      testPackage.workingDirectory == null
          ? workspaceRootPath
          : Directory(testPackage.workingDirectory!).absolute.path,
    );
    final testRootPath = _normalizeTestPath('$packageRootPath/test');
    final testRootPrefix = '$testRootPath${Platform.pathSeparator}';
    final isTestRoot = absolutePath == testRootPath;
    final isUnderTestRoot = absolutePath.startsWith(testRootPrefix);
    if (!isTestRoot && !isUnderTestRoot) {
      continue;
    }

    final relativeTarget =
        absolutePath == testRootPath
            ? 'test'
            : 'test/${absolutePath.substring(testRootPath.length + 1)}';

    return _ExplicitTestTarget(
      packagePath: testPackage.packagePath,
      relativeTarget: relativeTarget,
    );
  }

  return null;
}

String _packageNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/');
  return segments.isEmpty ? path : segments.last;
}

bool _flutterTestOptionConsumesNextValue(String arg) {
  return _flutterTestOptionsWithValue.contains(arg);
}

String _normalizeTestPath(String path) {
  final normalized =
      path
          .replaceAll('/', Platform.pathSeparator)
          .replaceAll('\\', Platform.pathSeparator);
  if (Platform.isWindows) {
    return normalized.replaceAll(RegExp(r'[\\\/]+$'), '').toLowerCase();
  }
  return normalized.replaceAll(RegExp(r'[\\\/]+$'), '');
}

Future<void> _prepareAndroidAuto(
  _BuildMode mode,
  List<String> androidTargets,
) async {
  if (androidTargets.isEmpty) {
    stdout.writeln('==> [SKIP] Android 原生产物: 未检测到 Android 设备');
    return;
  }

  await _prepareAndroidNative(mode, androidTargets);
}

Future<void> _prepareIosAuto(
  _BuildMode mode,
  List<_FlutterDevice> devices,
) async {
  final hasIosDevice = devices.any((device) => device.targetPlatform == 'ios');
  if (!hasIosDevice) {
    stdout.writeln('==> [SKIP] iOS 原生产物: 未检测到 iOS 设备或模拟器');
    return;
  }

  await _runAutoPrepareStep(
    label: 'iOS 原生产物',
    check: () => _checkIosAutoPrepare(mode),
    action: () => _prepareIosNative(mode),
  );
}

Future<void> _runAutoPrepareStep({
  required String label,
  required Future<_AutoPrepareCheck> Function() check,
  required Future<void> Function() action,
}) async {
  final result = await check();
  if (!result.ready) {
    stdout.writeln('==> [SKIP] $label: ${result.reason}');
    return;
  }
  await action();
}

String _parseNativeTarget(List<String> args) {
  for (final arg in args) {
    if (!arg.startsWith('-')) {
      return arg;
    }
  }
  return 'desktop';
}

_BuildMode _parseBuildMode(List<String> args) {
  if (args.contains('--debug')) {
    return _BuildMode.debug;
  }
  if (args.contains('--release') || args.contains('--profile')) {
    return _BuildMode.release;
  }
  return _BuildMode.release;
}

List<String>? _parseTargetPlatforms(List<String> args) {
  for (var index = 0; index < args.length; index++) {
    final value = args[index];
    if (value == '--target-platform') {
      if (index + 1 < args.length) {
        return args[index + 1]
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
      return null;
    }
    if (value.startsWith('--target-platform=')) {
      return value
          .substring('--target-platform='.length)
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
  }
  return null;
}

Future<void> _prepareDesktopHost(_BuildMode mode, {String? arch}) {
  if (Platform.isWindows) {
    return _prepareWindowsNative(mode);
  }
  if (Platform.isMacOS) {
    return _prepareMacOsNative(mode, arch: arch);
  }
  if (Platform.isLinux) {
    return _prepareLinuxNative(mode);
  }
  stderr.writeln('desktop 仅支持 Windows / macOS / Linux');
  exit(64);
}

Future<void> _prepareWindowsNative(_BuildMode mode) async {
  _assertHostPlatform('windows');

  final stagedOutputs = _windowsStagedOutputs;

  if (_nativeStageCurrent('windows', mode, stagedOutputs)) {
    stdout.writeln('==> Windows 网络核心产物已是最新状态');
    return;
  }

  await runOrExit(
    title: '构建 Windows 网络核心',
    executable: 'cargo',
    arguments: ['build', if (mode == _BuildMode.release) '--release', '--lib'],
    workingDirectory: _netCoreDir,
  );

  final cargoDir = mode == _BuildMode.release ? 'release' : 'debug';
  _stageFile('$_netCoreDir/target/$cargoDir/fluxdo_net.dll', stagedOutputs[0]);
  _writeNativeStageStamp('windows', mode);
}

Future<void> _prepareMacOsNative(_BuildMode mode, {String? arch}) async {
  _assertHostPlatform('macos');

  final resolvedArch = arch ?? await _detectMacOsHostArch();
  final macTarget = _resolveMacOsArch(resolvedArch);
  final variantKey = _macOsVariantKey(macTarget);

  final stagedOutputs = _macOsStagedOutputs;

  if (_nativeStageCurrent(
    'macos',
    mode,
    stagedOutputs,
    variantKey: variantKey,
  )) {
    stdout.writeln('==> macOS 网络核心产物已是最新状态(${macTarget.arch})');
    return;
  }

  await runOrExit(
    title: '构建 macOS 网络核心(${macTarget.arch})',
    executable: 'cargo',
    arguments: [
      'build',
      if (mode == _BuildMode.release) '--release',
      '--lib',
      '--target',
      macTarget.rustTarget,
    ],
    workingDirectory: _netCoreDir,
  );

  final cargoDir = mode == _BuildMode.release ? 'release' : 'debug';
  final base = '$_netCoreDir/target/${macTarget.rustTarget}/$cargoDir';
  _stageFile('$base/libfluxdo_net.dylib', stagedOutputs[0]);
  _writeNativeStageStamp('macos', mode, variantKey: variantKey);
}

Future<void> _prepareLinuxNative(_BuildMode mode) async {
  _assertHostPlatform('linux');

  final stagedOutputs = _linuxStagedOutputs;
  if (_nativeStageCurrent('linux', mode, stagedOutputs)) {
    stdout.writeln('==> Linux 网络核心产物已是最新状态');
    return;
  }

  await runOrExit(
    title: '构建 Linux 网络核心',
    executable: 'cargo',
    arguments: ['build', if (mode == _BuildMode.release) '--release', '--lib'],
    workingDirectory: _netCoreDir,
  );

  final cargoDir = mode == _BuildMode.release ? 'release' : 'debug';
  _stageFile('$_netCoreDir/target/$cargoDir/libfluxdo_net.so', stagedOutputs[0]);
  _writeNativeStageStamp('linux', mode);
}

Future<void> _prepareAndroidNative(
  _BuildMode mode,
  List<String>? targetPlatforms,
) async {
  final androidTargets = _resolveAndroidTargets(targetPlatforms);
  final stagedOutputs = _androidStagedOutputs(androidTargets);
  final variantKey = _androidVariantKey(androidTargets);

  if (_nativeStageCurrent(
    'android',
    mode,
    stagedOutputs,
    variantKey: variantKey,
  )) {
    stdout.writeln('==> Android 网络核心产物已是最新状态');
    return;
  }

  final environment = await _checkedAndroidNativeEnvironment(androidTargets);

  final cargoArgs = <String>[
    'ndk',
    ...[
      for (final target in androidTargets) ...['-t', target.androidAbi],
    ],
    '--platform',
    '28',
    'build',
    if (mode == _BuildMode.release) '--release',
    '--lib',
  ];
  if (Platform.isWindows) {
    final compilerDirectory = '${environment['ANDROID_NDK_HOME']}'
        '/toolchains/llvm/prebuilt/windows-x86_64/bin';
    // bindgen 也要能执行 NDK clang，才能找到对应的 C 标准头文件目录。
    cargoArgs.addAll([
      '--config',
      'env.CLANG_PATH.value=${jsonEncode('$compilerDirectory/clang.exe')}',
      '--config',
      'env.CLANG_PATH.force=true',
    ]);
    // cargo-ndk 的路径带反斜杠且缺少 .exe，BoringSSL 直接写入 CMake 后
    // 会在重新配置时报转义错误。由 Cargo 在启动构建脚本时覆盖这两个值。
    for (final target in androidTargets) {
      for (final compiler in {'CC': 'clang.exe', 'CXX': 'clang++.exe'}.entries) {
        final key = '${compiler.key}_${target.rustTarget}';
        cargoArgs.addAll([
          '--config',
          'env.$key.value=${jsonEncode('$compilerDirectory/${compiler.value}')}',
          '--config',
          'env.$key.force=true',
        ]);
      }
    }
  }
  await runOrExit(
    title: '构建 Android 网络核心',
    executable: 'cargo',
    arguments: cargoArgs,
    workingDirectory: _netCoreDir,
    environment: environment,
  );

  final cargoDir = mode == _BuildMode.release ? 'release' : 'debug';
  for (final target in androidTargets) {
    _stageFile(
      '$_netCoreDir/target/${target.rustTarget}/$cargoDir/libfluxdo_net.so',
      'android/app/src/main/jniLibs/${target.androidAbi}/libfluxdo_net.so',
    );
    // 旧核心的库若还留在 jniLibs 里会被一起打包，白占体积
    final legacy = File(
      'android/app/src/main/jniLibs/${target.androidAbi}/libdoh_proxy.so',
    );
    if (legacy.existsSync()) legacy.deleteSync();
  }
  _writeNativeStageStamp('android', mode, variantKey: variantKey);
}

Future<void> _prepareIosNative(_BuildMode mode) async {
  _assertHostPlatform('macos');

  final stagedOutputs = _iosStagedOutputs;

  if (_nativeStageCurrent('ios', mode, stagedOutputs)) {
    stdout.writeln('==> iOS 网络核心产物已是最新状态');
    return;
  }

  final buildArgs = <String>[
    'rustc',
    if (mode == _BuildMode.release) '--release',
    '--lib',
    '--crate-type',
    'staticlib',
  ];

  await runOrExit(
    title: '构建 iOS device 网络核心',
    executable: 'cargo',
    arguments: [...buildArgs, '--target', 'aarch64-apple-ios'],
    workingDirectory: _netCoreDir,
  );
  await runOrExit(
    title: '构建 iOS simulator 网络核心',
    executable: 'cargo',
    arguments: [...buildArgs, '--target', 'aarch64-apple-ios-sim'],
    workingDirectory: _netCoreDir,
  );

  final cargoDir = mode == _BuildMode.release ? 'release' : 'debug';
  _stageFile(
    '$_netCoreDir/target/aarch64-apple-ios/$cargoDir/libfluxdo_net.a',
    stagedOutputs[0],
  );
  _stageFile(
    '$_netCoreDir/target/aarch64-apple-ios-sim/$cargoDir/libfluxdo_net.a',
    stagedOutputs[1],
  );
  _writeNativeStageStamp('ios', mode);
}

bool _nativeStageCurrent(
  String target,
  _BuildMode mode,
  List<String> outputs, {
  String? variantKey,
}) {
  final stageStamp = File(_nativeStageStampPath(target));
  if (!stageStamp.existsSync()) {
    return false;
  }

  if (outputs.any((path) => !File(path).existsSync())) {
    return false;
  }

  return stageStamp.readAsStringSync() ==
      _nativeStageStampContent(mode, variantKey: variantKey);
}

void _writeNativeStageStamp(
  String target,
  _BuildMode mode, {
  String? variantKey,
}) {
  final stampFile = File(_nativeStageStampPath(target));
  stampFile.parent.createSync(recursive: true);
  stampFile.writeAsStringSync(
    _nativeStageStampContent(mode, variantKey: variantKey),
  );
}

String _nativeStageStampPath(String target) =>
    '.dart_tool/fluxdo_tooling/native/$target.stamp';

String _nativeStageStampContent(_BuildMode mode, {String? variantKey}) {
  final lines = <String>['mode=${mode.name}'];
  if (variantKey != null) {
    lines.add(variantKey);
  }
  lines.add(_rustInputStamp());
  return lines.join('\n');
}

String _rustInputStamp() {
  final trackedFiles =
      <File>[
          File('$_netCoreDir/Cargo.toml'),
          File('$_netCoreDir/Cargo.lock'),
          File('$_netCoreDir/build.rs'),
          File('$_netCoreDir/.cargo/config.toml'),
          ..._collectFiles('$_netCoreDir/src'),
          ..._collectFiles('$_netCoreDir/vendor'),
        ].where((file) => file.existsSync()).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  return trackedFiles
      .map((file) {
        final stat = file.statSync();
        return '${file.path}|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
      })
      .join('\n');
}

Iterable<File> _collectFiles(String path) sync* {
  final directory = Directory(path);
  if (!directory.existsSync()) {
    return;
  }

  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) {
      yield entity;
    }
  }
}

void _stageFile(String sourcePath, String targetPath) {
  final source = File(sourcePath);
  if (!source.existsSync()) {
    stderr.writeln('缺少构建产物: $sourcePath');
    exit(1);
  }

  final target = File(targetPath);
  target.parent.createSync(recursive: true);
  source.copySync(target.path);
  target.setLastModifiedSync(source.lastModifiedSync());
}

Future<void> _runProjectPrep(String command) {
  return runOrExit(
    title: '执行项目预处理 $command',
    executable: Platform.resolvedExecutable,
    arguments: ['tool/project_prep.dart', command],
  );
}

List<_AndroidTarget> _resolveAndroidTargets(List<String>? targetPlatforms) {
  if (targetPlatforms == null || targetPlatforms.isEmpty) {
    return _allAndroidTargets;
  }

  final resolved = <_AndroidTarget>{};
  for (final targetPlatform in targetPlatforms) {
    final target = switch (targetPlatform) {
      'android-arm64' || 'arm64-v8a' => _allAndroidTargets[0],
      'android-arm' || 'armeabi-v7a' => _allAndroidTargets[1],
      'android-x64' || 'x86_64' => _allAndroidTargets[2],
      'android-x86' || 'x86' => _allAndroidTargets[3],
      _ => null,
    };
    if (target != null) {
      resolved.add(target);
    }
  }
  if (resolved.isEmpty) {
    return _allAndroidTargets;
  }
  return _allAndroidTargets.where(resolved.contains).toList();
}

Future<_AutoPrepareCheck> _checkDesktopAutoPrepare(
  String target,
  _BuildMode mode,
) async {
  final stagedOutputs = switch (target) {
    'windows' => _windowsStagedOutputs,
    'macos' => _macOsStagedOutputs,
    'linux' => _linuxStagedOutputs,
    _ => const <String>[],
  };

  // macOS 走 host 架构默认编译,缓存戳带 arch variantKey,
  // 这里必须用同一 key 才能正确命中(否则永远 cache miss)。
  final variantKey = target == 'macos'
      ? _macOsVariantKey(_resolveMacOsArch(await _detectMacOsHostArch()))
      : null;

  if (_nativeStageCurrent(target, mode, stagedOutputs, variantKey: variantKey)) {
    return const _AutoPrepareCheck.ready();
  }

  if (!await _canRun('cargo', const ['--version'])) {
    return const _AutoPrepareCheck.skip('未找到 cargo');
  }

  return const _AutoPrepareCheck.ready();
}

Future<_AutoPrepareCheck> _checkIosAutoPrepare(_BuildMode mode) async {
  if (_nativeStageCurrent('ios', mode, _iosStagedOutputs)) {
    return const _AutoPrepareCheck.ready();
  }

  if (!await _canRun('cargo', const ['--version'])) {
    return const _AutoPrepareCheck.skip('未找到 cargo');
  }
  if (!await _canRun('xcrun', const ['--sdk', 'iphoneos', '--show-sdk-path'])) {
    return const _AutoPrepareCheck.skip('未找到 Xcode iPhoneOS SDK');
  }
  if (!await _canRun('xcrun', const [
    '--sdk',
    'iphonesimulator',
    '--show-sdk-path',
  ])) {
    return const _AutoPrepareCheck.skip('未找到 Xcode iPhone Simulator SDK');
  }

  return _checkRustTargets(const [
    'aarch64-apple-ios',
    'aarch64-apple-ios-sim',
  ]);
}

Future<_AutoPrepareCheck> _checkRustTargets(Iterable<String> targets) async {
  final result = await _runProcess('rustup', const [
    'target',
    'list',
    '--installed',
  ]);
  if (result.exitCode != 0) {
    return const _AutoPrepareCheck.skip('未找到 rustup，无法确认 Rust 交叉编译 target');
  }

  final installedTargets = result.combinedOutput
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toSet();
  final missingTargets = targets
      .where((target) => !installedTargets.contains(target))
      .toList(growable: false);
  if (missingTargets.isNotEmpty) {
    return _AutoPrepareCheck.skip(
      '缺少 Rust target: ${missingTargets.join(', ')}',
    );
  }

  return const _AutoPrepareCheck.ready();
}

Future<bool> _canRun(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await _runProcess(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  return result.exitCode == 0;
}

Future<_ProcessResult> _runProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: Platform.isWindows,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return _ProcessResult(
      exitCode: result.exitCode,
      combinedOutput: '${result.stdout}${result.stderr}',
    );
  } on ProcessException catch (error) {
    return _ProcessResult(exitCode: 1, combinedOutput: error.message);
  }
}

Future<List<_FlutterDevice>> _loadFlutterDevices() async {
  try {
    final result = await Process.run(
      flutterExecutable,
      const ['devices', '--machine'],
      runInShell: Platform.isWindows,
      workingDirectory: workspaceRootPath,
      environment: await androidBuildEnvironment(),
    );
    if (result.exitCode != 0) {
      return const [];
    }

    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! List) {
      return const [];
    }

    return decoded
        .whereType<Map>()
        .map((item) => _FlutterDevice.fromJson(item.cast<String, dynamic>()))
        .whereType<_FlutterDevice>()
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

List<String> _connectedAndroidTargetPlatforms(List<_FlutterDevice> devices) {
  final resolved = <String>{};
  for (final device in devices) {
    if (device.targetPlatform.startsWith('android')) {
      resolved.add(device.targetPlatform);
    }
  }
  if (resolved.isEmpty) {
    return const [];
  }
  return _resolveAndroidTargets(
    resolved.toList(),
  ).map((target) => target.flutterTarget).toList(growable: false);
}

Directory? _resolveAndroidNdkDirectory() {
  for (final candidate in _androidNdkCandidates()) {
    if (candidate.existsSync()) {
      // CMake 会记录磁盘上的路径大小写，后续必须传入同一路径才能复用缓存。
      return Directory(candidate.resolveSymbolicLinksSync());
    }
  }
  return null;
}

Future<Map<String, String>> _checkedAndroidNativeEnvironment(
  List<_AndroidTarget> targets,
) async {
  stdout.writeln(
    '==> Android 核心预检（${targets.map((target) => target.androidAbi).join(', ')}）',
  );
  final ndk = _resolveAndroidNdkDirectory();
  final environment = ndk == null
      ? Map<String, String>.from(Platform.environment)
      : await _androidNativeBuildEnvironment(ndk);
  final problems = <String>[];

  Future<void> checkCommand(
    String label,
    String executable,
    List<String> arguments,
    String fix,
  ) async {
    if (await _canRun(executable, arguments, environment: environment)) {
      stdout.writeln('[OK] $label');
    } else {
      problems.add('$label 无法运行。$fix');
    }
  }

  await checkCommand('Cargo', 'cargo', const [
    '--version',
  ], '请安装 Rust 工具链 https://rustup.rs/，并将 Cargo 加入 PATH。');
  await checkCommand('cargo-ndk', 'cargo', const [
    'ndk',
    '--version',
  ], '执行 cargo install cargo-ndk。');
  await checkCommand('Git', 'git', const [
    '--version',
  ], '请安装 Git 并加入 PATH，BoringSSL 构建需要应用补丁。');
  final rustTargets = targets.map((target) => target.rustTarget).toList();
  final rustCheck = await _checkRustTargets(rustTargets);
  if (rustCheck.ready) {
    stdout.writeln('[OK] Rust targets（${rustTargets.join(', ')}）');
  } else {
    problems.add(
      '${rustCheck.reason}。执行 rustup target add ${rustTargets.join(' ')}；'
      '如果 rustup 不可用，请先安装 Rust 工具链。',
    );
  }

  if (ndk == null) {
    problems.add(
      'Android NDK 缺失。请在 Android Studio SDK Manager 安装 NDK，'
      '或将 ANDROID_NDK_HOME 指向已安装的 NDK。',
    );
  } else {
    final toolchain = File('${ndk.path}/build/cmake/android.toolchain.cmake');
    if (!toolchain.existsSync()) {
      problems.add('Android NDK 不完整，缺少 ${toolchain.path}。请重新安装 NDK。');
    } else {
      stdout.writeln('[OK] Android NDK（${ndk.path}）');
    }
    final host = Platform.isWindows
        ? 'windows-x86_64'
        : Platform.isMacOS
        ? 'darwin-x86_64'
        : 'linux-x86_64';
    final suffix = Platform.isWindows ? '.exe' : '';
    final compilerBin = '${ndk.path}/toolchains/llvm/prebuilt/$host/bin';
    await checkCommand('NDK clang', '$compilerBin/clang$suffix', const [
      '--version',
    ], '请检查 NDK 是否包含当前宿主机的 LLVM 工具链。');
    await checkCommand('NDK clang++', '$compilerBin/clang++$suffix', const [
      '--version',
    ], '请检查 NDK 是否包含当前宿主机的 LLVM 工具链。');
    final resourceDir = await _runProcess('$compilerBin/clang$suffix', const [
      '-print-resource-dir',
    ], environment: environment);
    if (resourceDir.exitCode != 0 ||
        !File('${resourceDir.combinedOutput.trim()}/include/stddef.h')
            .existsSync()) {
      problems.add('NDK Clang 标准头文件缺失，无法找到 stddef.h。请重新安装 NDK。');
    }
  }

  final cmake = await _runProcess(environment['CMAKE'] ?? 'cmake', const [
    '--version',
  ], environment: environment);
  final cmakeVersion = RegExp(r'cmake version (\d+)\.(\d+)')
      .firstMatch(cmake.combinedOutput);
  final cmakeSupported =
      cmakeVersion != null &&
      (int.parse(cmakeVersion[1]!) > 3 ||
          (int.parse(cmakeVersion[1]!) == 3 &&
              int.parse(cmakeVersion[2]!) >= 22));
  if (cmake.exitCode != 0 || !cmakeSupported) {
    problems.add(
      'CMake 需要 3.22 或更高版本且能运行。请在 SDK Manager 安装 CMake，'
      '或安装新版 cmake 并加入 PATH / 设置 CMAKE。',
    );
  } else {
    stdout.writeln('[OK] ${cmakeVersion[0]}');
  }
  final generator = environment['CMAKE_GENERATOR']?.trim() ?? '';
  if (generator.startsWith('Ninja') ||
      (Platform.isWindows && generator.isEmpty)) {
    await checkCommand('Ninja', 'ninja', const [
      '--version',
    ], '请安装 SDK Manager 中的 CMake（包含 Ninja），或将 ninja 加入 PATH。');
  } else if (generator == 'Unix Makefiles' ||
      (!Platform.isWindows && generator.isEmpty)) {
    await checkCommand('Make', 'make', const [
      '--version',
    ], '请安装 make，或设置 CMAKE_GENERATOR=Ninja 并安装 ninja。');
  } else if (Platform.isWindows && generator.startsWith('Visual Studio')) {
    problems.add('Android NDK 不支持当前 CMAKE_GENERATOR=$generator。请使用 Ninja。');
  }

  final libclang = await _findLoadableLibclang(environment);
  if (libclang == null) {
    final install = Platform.isWindows
        ? 'winget install --id LLVM.LLVM --exact'
        : Platform.isMacOS
        ? 'brew install llvm'
        : 'sudo apt-get install libclang-dev';
    problems.add(
      'libclang 无法加载或缺少 Clang C API。执行 $install，'
      '并将 LIBCLANG_PATH 指向该库或所在目录（当前值 ${environment['LIBCLANG_PATH'] ?? '未设置'}）。',
    );
  } else {
    // 把验证通过的实际路径交给 bindgen，避免预检与编译搜索到不同的库。
    environment['LIBCLANG_PATH'] = libclang;
    stdout.writeln('[OK] libclang（$libclang）');
  }

  if (problems.isNotEmpty) {
    for (final problem in problems) {
      stderr.writeln('[MISSING] $problem');
    }
    stderr.writeln('Android 核心预检失败，共 ${problems.length} 项，请修复后重试。');
    exit(1);
  }
  stdout.writeln('==> Android 核心预检通过');
  return environment;
}

Future<String?> _findLoadableLibclang(Map<String, String> environment) async {
  final configured = environment['LIBCLANG_PATH']?.trim();
  final locations = <String>[];
  if (configured != null && configured.isNotEmpty) {
    locations.add(configured);
  } else {
    final llvm = environment['LLVM_CONFIG_PATH'] ?? 'llvm-config';
    final libdir = await _runProcess(llvm, const [
      '--libdir',
    ], environment: environment);
    if (libdir.exitCode == 0) {
      final directory = Directory(libdir.combinedOutput.trim());
      locations.addAll([directory.path, '${directory.parent.path}/bin']);
    }
    final path =
        environment.entries
            .where((entry) => entry.key.toUpperCase() == 'PATH')
            .map((entry) => entry.value)
            .firstOrNull ??
        '';
    locations.addAll(
      path
          .split(Platform.isWindows ? ';' : ':')
          .where((entry) => entry.isNotEmpty),
    );
    if (Platform.isWindows) {
      locations.addAll([
        '${environment['ProgramFiles'] ?? r'C:\Program Files'}/LLVM/bin',
        '${environment['USERPROFILE']}/scoop/apps/llvm/current/bin',
      ]);
    } else if (Platform.isMacOS) {
      locations.addAll([
        '/opt/homebrew/opt/llvm/lib',
        '/usr/local/opt/llvm/lib',
        '/Library/Developer/CommandLineTools/usr/lib',
      ]);
      final xcode = await _runProcess('xcode-select', const ['-p']);
      if (xcode.exitCode == 0) {
        locations.add(
          '${xcode.combinedOutput.trim()}/Toolchains/XcodeDefault.xctoolchain/usr/lib',
        );
      }
    } else {
      locations.addAll([
        '/usr/lib',
        '/usr/lib64',
        '/usr/local/lib',
        '/usr/lib/x86_64-linux-gnu',
        '/usr/lib/aarch64-linux-gnu',
      ]);
      final usrLib = Directory('/usr/lib');
      if (usrLib.existsSync()) {
        locations.addAll(
          usrLib
              .listSync()
              .whereType<Directory>()
              .where((directory) => directory.path.startsWith('/usr/lib/llvm-'))
              .map((directory) => '${directory.path}/lib'),
        );
      }
    }
  }
  for (final location in locations.toSet()) {
    final directory = Directory(location);
    Iterable<File> files;
    try {
      files = directory.existsSync()
          ? directory.listSync().whereType<File>().where((file) {
              final name = file.uri.pathSegments.last;
              return Platform.isWindows
                  ? name == 'libclang.dll' || name == 'clang.dll'
                  : Platform.isMacOS
                  ? name == 'libclang.dylib'
                  : name.startsWith('libclang') && name.contains('.so');
            })
          : [File(location)];
    } on FileSystemException {
      continue;
    }
    for (final file in files) {
      if (!file.existsSync()) continue;
      try {
        final library = DynamicLibrary.open(file.absolute.path);
        final valid =
            library.providesSymbol('clang_createIndex') &&
            library.providesSymbol('clang_disposeIndex') &&
            library.providesSymbol('clang_parseTranslationUnit2');
        library.close();
        if (valid) return file.absolute.path;
      } on ArgumentError {
        // 继续尝试同一搜索范围内的其他库，例如不同位数或版本。
      }
    }
  }
  return null;
}

Future<Map<String, String>> _androidNativeBuildEnvironment(
  Directory ndkDirectory,
) async {
  // cargo-ndk 会自行查找 NDK，BoringSSL 的构建脚本则要求显式传入路径。
  final ndkPath = ndkDirectory.absolute.path.replaceAll('\\', '/');
  final environment = Map<String, String>.from(Platform.environment)
    ..['ANDROID_NDK_HOME'] = ndkPath
    ..['ANDROID_NDK_ROOT'] = ndkPath;

  // Android Studio 安装的 CMake/Ninja 通常不在终端 PATH 中。
  final parentName = ndkDirectory.parent.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .lastOrNull;
  final sdkDirectory = parentName == 'ndk'
      ? ndkDirectory.parent.parent
      : ndkDirectory.parent;
  final cmakeDirectory = Directory('${sdkDirectory.path}/cmake');
  if (cmakeDirectory.existsSync()) {
    final versions =
        cmakeDirectory
            .listSync(followLinks: false)
            .whereType<Directory>()
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    final executable = Platform.isWindows ? 'cmake.exe' : 'cmake';
    final available = versions.where(
      (version) => File('${version.path}/bin/$executable').existsSync(),
    );
    if (available.isNotEmpty) {
      final pathKey = environment.keys.firstWhere(
        (key) => key.toUpperCase() == 'PATH',
        orElse: () => 'PATH',
      );
      final separator = Platform.isWindows ? ';' : ':';
      environment[pathKey] =
          '${environment[pathKey] ?? ''}'
          '$separator${available.first.path}${Platform.pathSeparator}bin';
    }
  }

  // Windows 的默认 Visual Studio generator 无法使用 Android NDK 工具链。
  if (Platform.isWindows &&
      (environment['CMAKE_GENERATOR']?.trim().isEmpty ?? true)) {
    final ninja = await _runProcess('ninja', const [
      '--version',
    ], environment: environment);
    if (ninja.exitCode == 0) environment['CMAKE_GENERATOR'] = 'Ninja';
  }
  return environment;
}

Iterable<Directory> _androidNdkCandidates() sync* {
  for (final envKey in const ['ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT']) {
    final value = Platform.environment[envKey]?.trim();
    if (value != null && value.isNotEmpty) {
      yield Directory(value);
    }
  }

  final localPropertiesFile = File('android/local.properties');
  if (localPropertiesFile.existsSync()) {
    final properties = _readSimpleProperties(localPropertiesFile);
    final ndkDirValue = _readNonBlank(properties, 'ndk.dir');
    if (ndkDirValue != null) {
      yield Directory(_decodePropertiesPath(ndkDirValue));
    }

    final sdkDirValue = _readNonBlank(properties, 'sdk.dir');
    if (sdkDirValue != null) {
      yield* _androidNdkCandidatesFromSdkRoot(
        _decodePropertiesPath(sdkDirValue),
      );
    }
  }

  for (final envKey in const ['ANDROID_SDK_ROOT', 'ANDROID_HOME']) {
    final value = Platform.environment[envKey]?.trim();
    if (value != null && value.isNotEmpty) {
      yield* _androidNdkCandidatesFromSdkRoot(value);
    }
  }

  final home = Platform
      .environment[Platform.isWindows ? 'LOCALAPPDATA' : 'HOME']
      ?.trim();
  if (Platform.isWindows && home != null && home.isNotEmpty) {
    yield* _androidNdkCandidatesFromSdkRoot('$home\\Android\\Sdk');
  } else if (Platform.isMacOS && home != null && home.isNotEmpty) {
    yield* _androidNdkCandidatesFromSdkRoot('$home/Library/Android/sdk');
  } else if (Platform.isLinux && home != null && home.isNotEmpty) {
    yield* _androidNdkCandidatesFromSdkRoot('$home/Android/Sdk');
    yield* _androidNdkCandidatesFromSdkRoot('$home/Android/sdk');
  }

  if (Platform.isLinux) {
    yield* _androidNdkCandidatesFromSdkRoot('/opt/android-sdk');
    yield* _androidNdkCandidatesFromSdkRoot('/usr/lib/android-sdk');
  }
}

Iterable<Directory> _androidNdkCandidatesFromSdkRoot(String sdkRoot) sync* {
  final ndkBundle = Directory('$sdkRoot${Platform.pathSeparator}ndk-bundle');
  if (ndkBundle.existsSync()) {
    yield ndkBundle;
  }

  final ndkDirectory = Directory('$sdkRoot${Platform.pathSeparator}ndk');
  if (!ndkDirectory.existsSync()) {
    return;
  }

  final versions =
      ndkDirectory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList(growable: false)
        ..sort((a, b) => b.path.compareTo(a.path));
  for (final version in versions) {
    yield version;
  }
}

Map<String, String> _readSimpleProperties(File file) {
  final properties = <String, String>{};
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) {
      continue;
    }

    final equalIndex = line.indexOf('=');
    final colonIndex = line.indexOf(':');
    final separatorIndex = equalIndex == -1
        ? colonIndex
        : colonIndex == -1
        ? equalIndex
        : equalIndex < colonIndex
        ? equalIndex
        : colonIndex;
    if (separatorIndex <= 0) {
      continue;
    }

    final key = line.substring(0, separatorIndex).trim();
    final value = line.substring(separatorIndex + 1).trim();
    if (key.isNotEmpty) {
      properties[key] = value;
    }
  }
  return properties;
}

String? _readNonBlank(Map<String, String> properties, String key) {
  final value = properties[key]?.trim();
  return value == null || value.isEmpty ? null : value;
}

String _decodePropertiesPath(String path) {
  return path
      .replaceAll(r'\:', ':')
      .replaceAll(r'\=', '=')
      .replaceAll('\\\\', '\\');
}

List<String> _androidStagedOutputs(List<_AndroidTarget> targets) {
  return targets
      .map(
        (target) =>
            'android/app/src/main/jniLibs/${target.androidAbi}/libfluxdo_net.so',
      )
      .toList(growable: false);
}

String _androidVariantKey(List<_AndroidTarget> targets) {
  return 'targets=${targets.map((target) => target.flutterTarget).join(',')}';
}

Future<String> _detectMacOsHostArch() async {
  // uname -m 在 Apple Silicon 上返回 'arm64',Intel 上返回 'x86_64'。
  // Platform.version 不含 CPU 架构信息,不可用于此判断。
  final result = await Process.run('uname', const ['-m']);
  final raw = (result.stdout as String).trim();
  return raw == 'arm64' ? 'arm64' : 'x86_64';
}

_MacOsArch _resolveMacOsArch(String arch) {
  return _macOsArchs.firstWhere(
    (item) => item.arch == arch,
    orElse: () {
      stderr.writeln('未知 macOS 架构: $arch(支持 arm64 / x86_64)');
      exit(64);
    },
  );
}

String _macOsVariantKey(_MacOsArch target) => 'arch=${target.arch}';

String? _parseMacOsArch(List<String> args) {
  for (final value in args) {
    if (value.startsWith('--arch=')) {
      final parsed = value.substring('--arch='.length).trim();
      return parsed.isEmpty ? null : parsed;
    }
  }
  final index = args.indexOf('--arch');
  if (index != -1 && index + 1 < args.length) {
    final parsed = args[index + 1].trim();
    return parsed.isEmpty ? null : parsed;
  }
  return null;
}

void _assertHostPlatform(String platform) {
  final matches =
      (platform == 'windows' && Platform.isWindows) ||
      (platform == 'macos' && Platform.isMacOS) ||
      (platform == 'linux' && Platform.isLinux);
  if (matches) {
    return;
  }

  stderr.writeln('$platform 原生产物只能在对应宿主平台上准备');
  exit(64);
}

const _usage = '''
用法:
  dart tool/project_tasks.dart app:clean
  dart tool/project_tasks.dart app:rebuild <flutter build args...>
  dart tool/project_tasks.dart test:all [flutter test args...]
  dart tool/project_tasks.dart run:prepare [--debug|--release|--profile] [--target-platform=<platforms>]
  dart tool/project_tasks.dart native:prepare [certs|auto|desktop|windows|macos|linux|android|ios|all] [--debug|--release|--profile] [--arch=arm64|x86_64]
  dart tool/project_tasks.dart native:doctor [--target-platform=android-arm64,android-arm,android-x64]
  dart tool/project_tasks.dart release:prepare [--skip-analyze] [--skip-test] [--strict-analyze]
''';

class _WorkspaceTestPackage {
  const _WorkspaceTestPackage({
    required this.label,
    required this.packagePath,
    required this.workingDirectory,
  });

  final String label;
  final String packagePath;
  final String? workingDirectory;
}

class _FlutterTestTask {
  const _FlutterTestTask({
    required this.label,
    required this.arguments,
    required this.workingDirectory,
  });

  final String label;
  final List<String> arguments;
  final String? workingDirectory;
}

class _ExplicitTestTarget {
  const _ExplicitTestTarget({
    required this.packagePath,
    required this.relativeTarget,
  });

  final String packagePath;
  final String relativeTarget;
}

const _flutterTestOptionsWithValue = <String>{
  '-n',
  '--name',
  '-N',
  '--plain-name',
  '-t',
  '--tags',
  '-x',
  '--exclude-tags',
  '-p',
  '--platform',
  '-j',
  '--concurrency',
  '-r',
  '--reporter',
  '--file-reporter',
  '--timeout',
  '--total-shards',
  '--shard-index',
  '--dart-define',
  '--dart-define-from-file',
  '--coverage-path',
  '--test-randomize-ordering-seed',
};

/// 网络核心 crate 目录。
const _netCoreDir = 'core/net_core';

const _windowsStagedOutputs = <String>['windows/runner/native/fluxdo_net.dll'];

const _macOsStagedOutputs = <String>['macos/Runner/native/libfluxdo_net.dylib'];

const _linuxStagedOutputs = <String>['linux/runner/native/libfluxdo_net.so'];

const _iosStagedOutputs = <String>[
  'ios/rust_libs/device/libfluxdo_net.a',
  'ios/rust_libs/simulator/libfluxdo_net.a',
];

const _allAndroidTargets = <_AndroidTarget>[
  _AndroidTarget('android-arm64', 'arm64-v8a', 'aarch64-linux-android'),
  _AndroidTarget('android-arm', 'armeabi-v7a', 'armv7-linux-androideabi'),
  _AndroidTarget('android-x64', 'x86_64', 'x86_64-linux-android'),
  _AndroidTarget('android-x86', 'x86', 'i686-linux-android'),
];

const _macOsArchs = <_MacOsArch>[
  _MacOsArch('arm64', 'aarch64-apple-darwin'),
  _MacOsArch('x86_64', 'x86_64-apple-darwin'),
];

class _AutoPrepareCheck {
  const _AutoPrepareCheck._(this.ready, this.reason);

  const _AutoPrepareCheck.ready() : this._(true, '');

  const _AutoPrepareCheck.skip(String reason) : this._(false, reason);

  final bool ready;
  final String reason;
}

class _AndroidTarget {
  const _AndroidTarget(this.flutterTarget, this.androidAbi, this.rustTarget);

  final String flutterTarget;
  final String androidAbi;
  final String rustTarget;
}

class _MacOsArch {
  const _MacOsArch(this.arch, this.rustTarget);

  final String arch; // 'arm64' | 'x86_64'
  final String rustTarget; // 'aarch64-apple-darwin' | 'x86_64-apple-darwin'
}

class _FlutterDevice {
  const _FlutterDevice({required this.id, required this.targetPlatform});

  final String id;
  final String targetPlatform;

  static _FlutterDevice? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim();
    final targetPlatform = json['targetPlatform']?.toString().trim();
    if (id == null ||
        id.isEmpty ||
        targetPlatform == null ||
        targetPlatform.isEmpty) {
      return null;
    }
    return _FlutterDevice(id: id, targetPlatform: targetPlatform);
  }
}

class _ProcessResult {
  const _ProcessResult({required this.exitCode, required this.combinedOutput});

  final int exitCode;
  final String combinedOutput;
}
