import 'dart:io';

import '_workspace_cli.dart';
import 'gen_l10n.dart' as gen_l10n;

const _certCrtPath = 'core/net_core/certs/ca.crt';
const _certDerPath = 'core/net_core/certs/ca.der';
const _assetCertPath = 'assets/certs/proxy_ca.pem';
const _androidCertPath = 'android/app/src/main/res/raw/proxy_ca.der';
const _androidKeyPropertiesPath = 'android/key.properties';

Future<void> main(List<String> args) async {
  await runProjectPrep(args);
}

Future<void> runProjectPrep(
  List<String> args, {
  bool forceL10n = false,
  Future<void> Function(List<String> doctorArgs)? onNativeDoctor,
}) async {
  enterWorkspaceRoot();

  final command = args.isEmpty ? 'app' : args.first;

  switch (command) {
    case 'app':
    case 'bootstrap':
      await _prepareApp(includeCerts: true, forceL10n: forceL10n);
      return;
    case 'test':
      await _prepareApp(includeCerts: false, forceL10n: forceL10n);
      return;
    case 'certs':
      await _ensureProxyCertResources();
      return;
    case 'doctor':
      await _runDoctor(args.sublist(1), onNativeDoctor: onNativeDoctor);
      return;
    case 'help':
    case '--help':
    case '-h':
      stdout.writeln(_usage);
      return;
    default:
      stderr.writeln('未知 project prep 子命令: $command');
      stderr.writeln(_usage);
      exit(64);
  }
}

Future<void> _prepareApp({
  required bool includeCerts,
  required bool forceL10n,
}) async {
  await syncIdeFlutterSdkLink(quiet: true);
  await ensurePubGet();
  await gen_l10n.runGenL10n(force: forceL10n);
  if (includeCerts) {
    await _ensureProxyCertResources();
  }
}

Future<void> _ensureProxyCertResources() async {
  final certCrt = File(_certCrtPath);
  final certDer = File(_certDerPath);

  if (!certCrt.existsSync() || !certDer.existsSync()) {
    stdout.writeln('==> 代理证书缺失，尝试生成...');
    if (!await _canRun('cargo', const ['--version'])) {
      stderr.writeln('!! 未找到 cargo，跳过代理证书生成与同步。');
      return;
    }
    await runOrExit(
      title: '生成代理证书',
      executable: 'cargo',
      arguments: const ['run', '--bin', 'gen_ca'],
      workingDirectory: 'core/net_core',
    );
  }

  if (!certCrt.existsSync() || !certDer.existsSync()) {
    stderr.writeln('!! 代理证书仍不存在，跳过资源同步。');
    return;
  }

  final syncedPaths = <String>[];

  if (_syncIfNeeded(certCrt, File(_assetCertPath))) {
    syncedPaths.add(_assetCertPath);
  }
  if (_syncIfNeeded(certDer, File(_androidCertPath))) {
    syncedPaths.add(_androidCertPath);
  }

  if (syncedPaths.isEmpty) {
    stdout.writeln('==> 代理证书资源已是最新状态');
    return;
  }

  stdout.writeln('==> 已同步代理证书资源:');
  for (final path in syncedPaths) {
    stdout.writeln('   - $path');
  }
}

bool _syncIfNeeded(File source, File target) {
  final targetExists = target.existsSync();
  final targetIsCurrent =
      targetExists &&
      !source.lastModifiedSync().isAfter(target.lastModifiedSync()) &&
      source.lengthSync() == target.lengthSync();

  if (targetIsCurrent) {
    return false;
  }

  target.parent.createSync(recursive: true);
  source.copySync(target.path);
  target.setLastModifiedSync(source.lastModifiedSync());
  return true;
}

Future<void> _runDoctor(
  List<String> args, {
  Future<void> Function(List<String> doctorArgs)? onNativeDoctor,
}) async {
  stdout.writeln('==> 检查开发环境');
  await _printCommandStatus(
    'mise',
    'mise',
    const ['--version'],
    optionalHint: '未安装（可选，可直接使用 dart tool/cli.dart）',
  );
  await _printCommandStatus('Flutter', flutterExecutable, const ['--version']);
  await _printCommandStatus('Dart', Platform.resolvedExecutable, const ['--version']);
  await _printCommandStatus('Cargo', 'cargo', const ['--version']);
  await _printAndroidJavaStatus();
  await _printIdeSdkLinkStatus();

  stdout.writeln('==> 检查 l10n 生成状态');
  final l10nResult = await _runProcess(
    Platform.resolvedExecutable,
    const ['tool/gen_l10n.dart', '--check'],
  );
  stdout.write(l10nResult.combinedOutput);
  stdout.writeln(
    l10nResult.exitCode == 0 ? '[OK] l10n 生成状态正常' : '[FAILED] l10n 生成状态异常',
  );

  stdout.writeln('==> 检查代理证书资源状态');
  final certCrt = File(_certCrtPath);
  final certDer = File(_certDerPath);
  final assetCert = File(_assetCertPath);
  final androidCert = File(_androidCertPath);

  _printFileStatus('core cert PEM', certCrt);
  _printFileStatus('core cert DER', certDer);
  _printSyncStatus('asset cert', certCrt, assetCert);
  _printSyncStatus('android cert', certDer, androidCert);

  stdout.writeln('==> 检查 Android 签名状态');
  _printAndroidSigningStatus();

  if (onNativeDoctor != null) {
    await onNativeDoctor(args);
    return;
  }

  await runOrExit(
    title: '检查 Android 网络核心构建环境',
    executable: Platform.resolvedExecutable,
    arguments: ['tool/project_tasks.dart', 'native:doctor', ...args],
  );
}

Future<void> _printIdeSdkLinkStatus() async {
  final sdkHome = resolveFlutterHome();
  final linkDir = Directory(ideFlutterSdkLinkPath);
  if (!linkDir.existsSync()) {
    stdout.writeln(
      '[MISSING] IDE Flutter SDK 链接 ($ideFlutterSdkLinkPath)，执行 mise r sdk:link 创建',
    );
    return;
  }
  final resolved = linkDir.resolveSymbolicLinksSync();
  if (sdkHome != null && resolved == Directory(sdkHome).resolveSymbolicLinksSync()) {
    stdout.writeln('[OK] IDE Flutter SDK 链接: $ideFlutterSdkLinkPath -> $resolved');
    return;
  }
  stdout.writeln(
    '[STALE] IDE Flutter SDK 链接: $ideFlutterSdkLinkPath -> $resolved (期望 $sdkHome)，执行 mise r sdk:link 修复',
  );
}

Future<void> _printAndroidJavaStatus() async {
  final runtime = await resolveAndroidJavaRuntime(forceProbe: true);
  if (runtime == null) {
    stdout.writeln('[MISSING] Android Gradle JDK: 未找到受支持的 JDK 17+/ < 26');
    return;
  }

  stdout.writeln(
    '[OK] Android Gradle JDK: Java ${runtime.majorVersion} @ ${runtime.home} (${runtime.source})',
  );
}

void _printFileStatus(String label, File file) {
  if (file.existsSync()) {
    stdout.writeln('[OK] $label: ${file.path}');
    return;
  }
  stdout.writeln('[MISSING] $label: ${file.path}');
}

void _printSyncStatus(String label, File source, File target) {
  if (!source.existsSync()) {
    stdout.writeln('[UNKNOWN] $label: 缺少源文件 ${source.path}');
    return;
  }
  if (!target.existsSync()) {
    stdout.writeln('[MISSING] $label: ${target.path}');
    return;
  }

  final inSync =
      !source.lastModifiedSync().isAfter(target.lastModifiedSync()) &&
      source.lengthSync() == target.lengthSync();
  stdout.writeln('[${inSync ? 'OK' : 'STALE'}] $label: ${target.path}');
}

void _printAndroidSigningStatus() {
  final keyPropertiesFile = File(_androidKeyPropertiesPath);
  if (!keyPropertiesFile.existsSync()) {
    stdout.writeln(
      '[FALLBACK] Android local signing: 缺少 $_androidKeyPropertiesPath，debug 使用默认 debug signing，profile/release 将回退 debug signing',
    );
    return;
  }

  final properties = _readSimpleProperties(keyPropertiesFile);
  final missingFields = <String>[
    if (_readNonBlank(properties, 'keyAlias') == null) 'keyAlias',
    if (_readNonBlank(properties, 'keyPassword') == null) 'keyPassword',
    if (_readNonBlank(properties, 'storePassword') == null) 'storePassword',
  ];

  final storeFileValue = _readNonBlank(properties, 'storeFile');
  final storeFile = _resolveAndroidStoreFile(storeFileValue);
  if (storeFileValue == null || storeFile == null || !storeFile.existsSync()) {
    missingFields.add('storeFile');
  }

  if (missingFields.isEmpty) {
    stdout.writeln(
      '[OK] Android local signing: ${storeFile!.path}（debug/profile/release）',
    );
    return;
  }

  stdout.writeln(
    '[FALLBACK] Android local signing: 配置不完整（${missingFields.join(', ')}），debug 使用默认 debug signing，profile/release 将回退 debug signing',
  );
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

File? _resolveAndroidStoreFile(String? rawPath) {
  final normalized = rawPath?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  final directFile = File(normalized);
  if (directFile.isAbsolute) {
    return directFile;
  }

  final candidates = <String>{
    'android/app/$normalized',
    'android/$normalized',
    normalized,
  };
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file;
    }
  }

  return File('android/$normalized');
}

Future<void> _printCommandStatus(
  String label,
  String executable,
  List<String> arguments, {
  String? optionalHint,
}) async {
  final result = await _runProcess(executable, arguments);
  if (result.exitCode == 0) {
    final firstLine = result.combinedOutput
        .split(RegExp(r'\r?\n'))
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    stdout.writeln('[OK] $label: $firstLine');
    return;
  }

  if (optionalHint != null) {
    stdout.writeln('[OPTIONAL] $label: $optionalHint');
    return;
  }

  stdout.writeln('[MISSING] $label');
}

Future<_ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      runInShell: Platform.isWindows,
    );
    return _ProcessResult(
      exitCode: result.exitCode,
      combinedOutput: '${result.stdout}${result.stderr}',
    );
  } on ProcessException catch (error) {
    return _ProcessResult(exitCode: 1, combinedOutput: error.message);
  }
}

Future<bool> _canRun(String executable, List<String> arguments) async {
  final result = await _runProcess(executable, arguments);
  return result.exitCode == 0;
}

class _ProcessResult {
  const _ProcessResult({required this.exitCode, required this.combinedOutput});

  final int exitCode;
  final String combinedOutput;
}

const _usage = '''
用法:
  dart tool/project_prep.dart app
  dart tool/project_prep.dart test
  dart tool/project_prep.dart certs
  dart tool/project_prep.dart doctor [--target-platform=android-arm64,android-arm,android-x64]
''';
