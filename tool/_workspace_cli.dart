import 'dart:io';

String get workspaceRootPath => _workspaceRootPath;

const ideFlutterSdkLinkPath = '.tooling/flutter_sdk';

String get flutterExecutable =>
    _readNonBlankEnv('FLUTTER_BIN') ??
    _resolveFlutterExecutableFromHome(_readNonBlankEnv('FLUXDO_FLUTTER_HOME')) ??
    _resolveFlutterExecutableFromHome(_readNonBlankEnv('FLUTTER_ROOT')) ??
    _resolveFlutterExecutableFromHome(_flutterHomeFromDartExecutable()) ??
    _resolveFlutterExecutableFromHome(_flutterHomeFromIdeLink()) ??
    _resolveFlutterExecutableFromHome(_flutterHomeFromIdeaDartSdk()) ??
    (Platform.isWindows ? 'flutter.bat' : 'flutter');

String get toolingStampPath =>
    '.dart_tool${Platform.pathSeparator}fluxdo_tooling${Platform.pathSeparator}pubspec.stamp';

String get l10nStampPath =>
    '.dart_tool${Platform.pathSeparator}fluxdo_tooling${Platform.pathSeparator}l10n.stamp';

final String _workspaceRootPath = _resolveWorkspaceRootPath();

AndroidJavaRuntime? _cachedAndroidJavaRuntime;
bool _didProbeAndroidJavaRuntime = false;

void enterWorkspaceRoot() {
  if (_normalizePath(Directory.current.path) ==
      _normalizePath(workspaceRootPath)) {
    return;
  }
  Directory.current = workspaceRootPath;
}

/// 解析当前激活的 Flutter SDK 根目录（用于 IDE 软链同步与诊断）。
String? resolveFlutterHome() {
  final candidates = <String?>[
    _readNonBlankEnv('FLUXDO_FLUTTER_HOME'),
    _readNonBlankEnv('FLUTTER_ROOT'),
    _flutterHomeFromDartExecutable(),
    _flutterHomeFromExecutable(_readNonBlankEnv('FLUTTER_BIN')),
    _flutterHomeFromIdeLink(),
    _flutterHomeFromIdeaDartSdk(),
  ];
  for (final candidate in candidates) {
    if (_resolveFlutterExecutableFromHome(candidate) != null) {
      return Directory(candidate!).resolveSymbolicLinksSync();
    }
  }
  return null;
}

/// 把当前激活的 Flutter SDK 同步到项目内固定路径 `.tooling/flutter_sdk`，
/// 供 VS Code (`.vscode/settings.json`) 与 Android Studio 统一引用。
///
/// - macOS / Linux：使用符号链接；
/// - Windows：使用目录联接（Junction，`mklink /J`），无需管理员或开发者模式权限。
///
/// 返回 `true` 表示链接已创建或已更新，`false` 表示本就是最新或无法解析 SDK。
Future<bool> syncIdeFlutterSdkLink({
  bool quiet = false,
  bool checkOnly = false,
}) async {
  final sdkHome = resolveFlutterHome();
  if (sdkHome == null) {
    if (!quiet) {
      stderr.writeln('!! 未解析到 Flutter SDK 路径，跳过 $ideFlutterSdkLinkPath 同步');
    }
    return false;
  }

  final linkFullPath =
      '$workspaceRootPath${Platform.pathSeparator}${ideFlutterSdkLinkPath.replaceAll('/', Platform.pathSeparator)}';
  final normalizedTarget = _normalizePath(
    Directory(sdkHome).resolveSymbolicLinksSync(),
  );

  final existingType = FileSystemEntity.typeSync(
    linkFullPath,
    followLinks: false,
  );
  if (existingType != FileSystemEntityType.notFound) {
    try {
      final currentResolved = _normalizePath(
        Directory(linkFullPath).resolveSymbolicLinksSync(),
      );
      if (currentResolved == normalizedTarget) {
        if (!quiet) {
          stdout.writeln('==> IDE Flutter SDK 链接已是最新: $ideFlutterSdkLinkPath -> $sdkHome');
        }
        return false;
      }
    } on FileSystemException {
      // 悬空链接，后续重建。
    }
  }

  if (checkOnly) {
    stderr.writeln(
      '[STALE] $ideFlutterSdkLinkPath 未指向当前 Flutter SDK ($sdkHome)，请执行 mise r sdk:link',
    );
    return true;
  }

  final parentDir = File(linkFullPath).parent;
  if (!parentDir.existsSync()) {
    parentDir.createSync(recursive: true);
  }

  if (existingType != FileSystemEntityType.notFound) {
    await _removeLinkOrDirectory(linkFullPath, existingType);
  }

  if (Platform.isWindows) {
    final result = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      linkFullPath,
      sdkHome,
    ]);
    if (result.exitCode != 0) {
      stderr.writeln(
        '!! 创建 Windows 目录联接失败 ($ideFlutterSdkLinkPath -> $sdkHome): ${result.stderr}',
      );
      return false;
    }
  } else {
    Link(linkFullPath).createSync(sdkHome);
  }

  if (!quiet) {
    stdout.writeln('==> 已同步 IDE Flutter SDK: $ideFlutterSdkLinkPath -> $sdkHome');
  }
  return true;
}

Future<void> _removeLinkOrDirectory(
  String path,
  FileSystemEntityType type,
) async {
  if (type == FileSystemEntityType.link) {
    Link(path).deleteSync();
    return;
  }
  if (Platform.isWindows && type == FileSystemEntityType.directory) {
    // Windows 下 Junction 在某些版本 Dart 中表现为 directory，rmdir 只拆联接不删目标内容。
    final result = await Process.run('cmd', ['/c', 'rmdir', path]);
    if (result.exitCode == 0) {
      return;
    }
  }
  if (type == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else {
    File(path).deleteSync();
  }
}

Future<void> ensurePubGet() async {
  final packageConfig = File('.dart_tool/package_config.json');
  final stampFile = File(toolingStampPath);
  final currentStamp = _buildPubspecStamp();

  final needsPubGet =
      !packageConfig.existsSync() ||
      !stampFile.existsSync() ||
      stampFile.readAsStringSync() != currentStamp;

  if (!needsPubGet) {
    return;
  }

  await runFlutterOrExit(
    title: '依赖信息缺失或已过期，先执行 flutter pub get',
    arguments: const ['pub', 'get'],
  );

  stampFile.parent.createSync(recursive: true);
  stampFile.writeAsStringSync(_buildPubspecStamp());
}

void resetPubGetStamp() {
  final stampFile = File(toolingStampPath);
  if (stampFile.existsSync()) {
    stampFile.deleteSync();
  }
}

void resetToolingStamps() {
  resetPubGetStamp();
  final l10nStamp = File(l10nStampPath);
  if (l10nStamp.existsSync()) {
    l10nStamp.deleteSync();
  }
}

Future<void> runOrExit({
  required String title,
  required String executable,
  required List<String> arguments,
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  stdout.writeln('==> $title...');
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    exit(exitCode);
  }
}

Future<void> runFlutterOrExit({
  required String title,
  required List<String> arguments,
  String? workingDirectory,
  bool requireAndroidJava = false,
}) async {
  await runOrExit(
    title: title,
    executable: flutterExecutable,
    arguments: arguments,
    workingDirectory: workingDirectory,
    environment: requireAndroidJava ? await androidBuildEnvironment() : null,
  );
}

Future<Map<String, String>> androidBuildEnvironment() async {
  final environment = Map<String, String>.from(Platform.environment);
  final runtime = await resolveAndroidJavaRuntime();
  if (runtime == null) {
    return environment;
  }

  environment['JAVA_HOME'] = runtime.home;
  environment['ORG_GRADLE_JAVA_HOME'] = runtime.home;

  final pathKey = _pathEnvironmentKey(environment);
  final pathListSeparator = Platform.isWindows ? ';' : ':';
  final javaBinPath = '${runtime.home}${Platform.pathSeparator}bin';
  final currentPath = environment[pathKey] ?? '';
  final pathEntries = currentPath
      .split(pathListSeparator)
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();
  final containsJavaBin = pathEntries.any(
    (entry) => _normalizePath(entry) == _normalizePath(javaBinPath),
  );
  if (!containsJavaBin) {
    environment[pathKey] = currentPath.isEmpty
        ? javaBinPath
        : '$javaBinPath$pathListSeparator$currentPath';
  }

  return environment;
}

Future<AndroidJavaRuntime?> resolveAndroidJavaRuntime({
  bool forceProbe = false,
}) async {
  if (_didProbeAndroidJavaRuntime && !forceProbe) {
    return _cachedAndroidJavaRuntime;
  }

  final seenHomes = <String>{};
  for (final candidate in _androidJavaHomeCandidates()) {
    final normalized = _normalizePath(candidate.home);
    if (!seenHomes.add(normalized)) {
      continue;
    }

    final runtime = await _probeAndroidJavaRuntime(candidate);
    if (runtime != null) {
      _cachedAndroidJavaRuntime = runtime;
      _didProbeAndroidJavaRuntime = true;
      return runtime;
    }
  }
  _cachedAndroidJavaRuntime = null;
  _didProbeAndroidJavaRuntime = true;
  return null;
}

Iterable<_AndroidJavaCandidate> _androidJavaHomeCandidates() sync* {
  // 优先尊重显式环境变量与 mise 注入的 JAVA_HOME（避免无谓扫盘）。
  for (final environmentKey in const [
    'FLUXDO_ANDROID_JAVA_HOME',
    'JAVA_HOME',
    'ANDROID_STUDIO_JDK',
    'STUDIO_JDK',
    'JAVA21_HOME',
    'JAVA17_HOME',
  ]) {
    final value = Platform.environment[environmentKey];
    if (value != null && value.trim().isNotEmpty) {
      yield _AndroidJavaCandidate(value.trim(), environmentKey);
    }
  }

  yield* _androidStudioJavaCandidates();
  yield* _commonJavaHomeCandidates();
}

Iterable<_AndroidJavaCandidate> _androidStudioJavaCandidates() sync* {
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      final googleDir = Directory('$localAppData\\Google');
      if (googleDir.existsSync()) {
        final studioHomes = googleDir
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where((directory) => directory.path.contains('AndroidStudio'))
            .map((directory) => File('${directory.path}\\.home'))
            .where((file) => file.existsSync());
        for (final homeFile in studioHomes) {
          final studioHome = homeFile
              .readAsLinesSync()
              .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
              .trim();
          if (studioHome.isEmpty) {
            continue;
          }
          yield _AndroidJavaCandidate(
            '$studioHome\\jbr',
            '${homeFile.path} -> jbr',
          );
          yield _AndroidJavaCandidate(
            '$studioHome\\jre',
            '${homeFile.path} -> jre',
          );
        }
      }
    }

    for (final root in const [
      r'C:\Program Files\Android\Android Studio',
      r'D:\Program Files\Android\Android Studio',
    ]) {
      yield _AndroidJavaCandidate('$root\\jbr', '$root\\jbr');
      yield _AndroidJavaCandidate('$root\\jre', '$root\\jre');
    }
    return;
  }

  if (Platform.isMacOS) {
    for (final root in const [
      '/Applications/Android Studio.app/Contents',
      '/Applications/Android Studio Preview.app/Contents',
    ]) {
      yield _AndroidJavaCandidate('$root/jbr/Contents/Home', '$root/jbr');
      yield _AndroidJavaCandidate('$root/jre/Contents/Home', '$root/jre');
    }
    return;
  }

  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    for (final root in [
      '$home/android-studio',
      '$home/android-studio-preview',
      '/opt/android-studio',
      '/snap/android-studio/current/android-studio',
    ]) {
      yield _AndroidJavaCandidate('$root/jbr', '$root/jbr');
      yield _AndroidJavaCandidate('$root/jre', '$root/jre');
    }
  }
}

Iterable<_AndroidJavaCandidate> _commonJavaHomeCandidates() sync* {
  if (!Platform.isWindows) {
    return;
  }

  for (final basePath in const [
    r'C:\Program Files\Java',
    r'D:\Program Files\Java',
  ]) {
    final baseDirectory = Directory(basePath);
    if (!baseDirectory.existsSync()) {
      continue;
    }

    for (final entity in baseDirectory.listSync(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      yield _AndroidJavaCandidate(entity.path, entity.path);
    }
  }
}

Future<AndroidJavaRuntime?> _probeAndroidJavaRuntime(
  _AndroidJavaCandidate candidate,
) async {
  final normalizedHome = _normalizePath(candidate.home);
  final javaExecutable =
      '$normalizedHome${Platform.pathSeparator}bin${Platform.pathSeparator}'
      '${Platform.isWindows ? 'java.exe' : 'java'}';
  final javaFile = File(javaExecutable);
  if (!javaFile.existsSync()) {
    return null;
  }

  try {
    final result = await Process.run(
      javaExecutable,
      const ['-version'],
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      return null;
    }

    final output = '${result.stdout}${result.stderr}';
    final match = RegExp(r'version "(\d+)').firstMatch(output);
    if (match == null) {
      return null;
    }

    final majorVersion = int.tryParse(match.group(1)!);
    if (majorVersion == null || majorVersion < 17 || majorVersion >= 26) {
      return null;
    }

    return AndroidJavaRuntime(
      home: normalizedHome,
      majorVersion: majorVersion,
      source: candidate.source,
    );
  } on ProcessException {
    return null;
  }
}

String _pathEnvironmentKey(Map<String, String> environment) {
  for (final key in environment.keys) {
    if (key.toLowerCase() == 'path') {
      return key;
    }
  }
  return Platform.isWindows ? 'Path' : 'PATH';
}

String _normalizePath(String path) {
  final normalized = path
      .replaceAll('/', Platform.pathSeparator)
      .replaceAll('\\', Platform.pathSeparator);
  if (Platform.isWindows) {
    return normalized.replaceAll(RegExp(r'[\\\/]+$'), '').toLowerCase();
  }
  return normalized.replaceAll(RegExp(r'[\\\/]+$'), '');
}

String _buildPubspecStamp() {
  final trackedFiles = <File>[
    File('pubspec.yaml'),
    File('pubspec.lock'),
    ..._packagePubspecFiles(),
  ].where((file) => file.existsSync()).toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  return trackedFiles.map((file) {
    final stat = file.statSync();
    return '${file.path}|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
  }).join('\n');
}

Iterable<File> _packagePubspecFiles() sync* {
  final packagesDir = Directory('packages');
  if (!packagesDir.existsSync()) {
    return;
  }

  for (final entity in packagesDir.listSync(followLinks: false)) {
    if (entity is! Directory) {
      continue;
    }
    yield File('${entity.path}${Platform.pathSeparator}pubspec.yaml');
  }
}

class AndroidJavaRuntime {
  const AndroidJavaRuntime({
    required this.home,
    required this.majorVersion,
    required this.source,
  });

  final String home;
  final int majorVersion;
  final String source;
}

class _AndroidJavaCandidate {
  const _AndroidJavaCandidate(this.home, this.source);

  final String home;
  final String source;
}

String _resolveWorkspaceRootPath() {
  final scriptDirectory = Directory.fromUri(Platform.script.resolve('.'));
  return scriptDirectory.parent.path;
}

String? _readNonBlankEnv(String key) {
  final value = Platform.environment[key]?.trim();
  return value == null || value.isEmpty ? null : value;
}

String? _resolveFlutterExecutableFromHome(String? flutterHome) {
  final normalizedHome = flutterHome?.trim();
  if (normalizedHome == null || normalizedHome.isEmpty) {
    return null;
  }

  final executable =
      '$normalizedHome${Platform.pathSeparator}bin${Platform.pathSeparator}'
      '${Platform.isWindows ? 'flutter.bat' : 'flutter'}';
  return File(executable).existsSync() ? executable : null;
}

String? _flutterHomeFromExecutable(String? executablePath) {
  final normalized = executablePath?.trim().replaceAll('\\', '/');
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  const marker = '/bin/';
  final markerIndex = normalized.lastIndexOf(marker);
  if (markerIndex <= 0) {
    return null;
  }
  return normalized
      .substring(0, markerIndex)
      .replaceAll('/', Platform.pathSeparator);
}

String? _flutterHomeFromDartExecutable() {
  final normalized = Platform.resolvedExecutable.replaceAll('\\', '/');
  const marker = '/bin/cache/dart-sdk/bin/';
  final markerIndex = normalized.lastIndexOf(marker);
  if (markerIndex <= 0) {
    return null;
  }
  return normalized
      .substring(0, markerIndex)
      .replaceAll('/', Platform.pathSeparator);
}

String? _flutterHomeFromIdeLink() {
  final linkDir = Directory(
    '$workspaceRootPath${Platform.pathSeparator}${ideFlutterSdkLinkPath.replaceAll('/', Platform.pathSeparator)}',
  );
  if (!linkDir.existsSync()) {
    return null;
  }
  return linkDir.path;
}

String? _flutterHomeFromIdeaDartSdk() {
  final ideaDartSdkFile = File('.idea/libraries/Dart_SDK.xml');
  if (!ideaDartSdkFile.existsSync()) {
    return null;
  }

  final match = RegExp(
    r'file://([^"]+?)[/\\]bin[/\\]cache[/\\]dart-sdk[/\\]lib[/\\]',
  ).firstMatch(ideaDartSdkFile.readAsStringSync());
  if (match == null) {
    return null;
  }

  return match.group(1)?.replaceAll('/', Platform.pathSeparator);
}
