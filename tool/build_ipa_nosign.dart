import 'dart:io';

import 'package:path/path.dart' as p;

import '_cli_ui.dart';
import '_workspace_cli.dart';

final _cliUi = CliUi();

Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  final yes = args.contains('--yes') || args.contains('-y');
  final filteredArgs = args
      .where((arg) => arg != '--yes' && arg != '-y')
      .toList(growable: false);

  if (!Platform.isMacOS) {
    _cliUi.error('iOS 无签名 IPA 只能在 macOS 上打包');
    exit(64);
  }

  _cliUi.intro('FluxDO iOS IPA', subtitle: '无签名 IPA 构建工具');

  final version = await _resolveVersion(filteredArgs);
  if (version.isEmpty) {
    _cliUi.cancel('已取消');
    return;
  }

  final ipaDir = Directory('build/ios/ipa')..createSync(recursive: true);
  final ipaPath = p.join(ipaDir.path, 'fluxdo-$version-nosign.ipa');

  _cliUi.summaryBox(
    title: '打包计划',
    rows: [
      CliSummaryRow('版本号', version, highlight: true),
      CliSummaryRow('输出路径', ipaPath),
      const CliSummaryRow('签名模式', '无签名 (--no-codesign)', dim: true),
    ],
  );
  stdout.writeln('');

  if (!yes &&
      (await _cliUi.confirm(
            prompt: '确认构建 iOS 无签名 IPA ($version)?',
            defaultValue: true,
          ) !=
          true)) {
    _cliUi.cancel('已取消构建');
    return;
  }

  final watch = Stopwatch()..start();
  _cliUi.step('[1/2] 构建 iOS 应用');
  await runOrExit(
    title: '构建 iOS 应用',
    executable: Platform.resolvedExecutable,
    arguments: const [
      'tool/flutterw.dart',
      'build',
      'ios',
      '--release',
      '--no-codesign',
    ],
  );

  final runnerApp = Directory('build/ios/iphoneos/Runner.app');
  if (!runnerApp.existsSync()) {
    _cliUi.error('缺少构建产物: ${runnerApp.path}');
    exit(1);
  }

  _cliUi.step('[2/2] 打包 IPA');
  final tempDir = await Directory.systemTemp.createTemp('fluxdo_ipa_');
  try {
    final payloadDir = Directory(p.join(tempDir.path, 'Payload'))
      ..createSync(recursive: true);
    await _copyDirectory(
      runnerApp,
      Directory(p.join(payloadDir.path, 'Runner.app')),
    );

    final ipaFile = File(ipaPath);
    if (ipaFile.existsSync()) {
      ipaFile.deleteSync();
    }

    await runOrExit(
      title: '压缩 Payload 为 IPA',
      executable: 'zip',
      arguments: ['-qr', ipaFile.absolute.path, 'Payload'],
      workingDirectory: tempDir.path,
    );
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }

  watch.stop();
  final sizeMb = (File(ipaPath).lengthSync() / (1024 * 1024)).toStringAsFixed(1);
  stdout.writeln('');
  _cliUi.summaryBox(
    title: 'IPA 构建完成',
    isSuccess: true,
    rows: [
      CliSummaryRow('输出文件', ipaPath, highlight: true),
      CliSummaryRow('文件大小', '$sizeMb MB'),
      CliSummaryRow(
        '总耗时',
        '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
      ),
    ],
  );
  stdout.writeln('');
}

Future<String> _resolveVersion(List<String> args) async {
  if (args.isNotEmpty) {
    return args.first.trim();
  }

  final pubspecVersion = _readVersionFromPubspec();
  if (!_cliUi.canPrompt) {
    return pubspecVersion;
  }

  final selected = await _cliUi.input(
    prompt: '输入 iOS 无签名 IPA 版本号',
    defaultValue: pubspecVersion,
  );
  return selected?.trim() ?? '';
}

String _readVersionFromPubspec() {
  final pubspecFile = File('pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    return '';
  }
  final match = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(
    pubspecFile.readAsStringSync(),
  );
  return match?.group(1)?.split('+').first.trim() ?? '';
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  destination.createSync(recursive: true);
  await for (final entity in source.list(recursive: false, followLinks: false)) {
    final targetPath = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(targetPath));
    } else if (entity is File) {
      File(targetPath).parent.createSync(recursive: true);
      await entity.copy(targetPath);
    }
  }
}

const _usage = '''
用法:
  mise r ipa [版本号] [-y|--yes]
  dart tool/build_ipa_nosign.dart [版本号] [-y|--yes]
''';
