import 'dart:io';

import '_cli_ui.dart';
import '_workspace_cli.dart';

final _versionPattern = RegExp(r'^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$');
final _cliUi = CliUi();

Future<void> main(List<String> args) async {
  enterWorkspaceRoot();

  var options = _parseArgs(args);
  if (options.showHelp) {
    stderr.writeln(_usage);
    exit(0);
  }

  final pubspecFile = File('pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    stderr.writeln('找不到 pubspec.yaml 文件');
    exit(1);
  }

  final currentVersion = _readCurrentVersion(pubspecFile);
  await _assertGitRepository();
  final currentBaseline = await _resolveCurrentBaseline(currentVersion);
  options = await _resolveReleaseOptions(options, currentBaseline.version);
  final targetVersion = _resolveTargetVersion(
    rawTarget: options.target!,
    current: currentBaseline.version,
    preid: options.preid,
    track: options.track,
  );
  final isPrerelease = targetVersion.isPrerelease;
  final releaseVersion = targetVersion.toString();
  final pubspecVersion = '$releaseVersion+${_buildVersionCode(DateTime.now())}';
  final tagName = 'v$releaseVersion';

  if (!options.dryRun) {
    await _assertCleanGitTree();
  }

  final currentBranch = await _gitStdout(['branch', '--show-current']);
  if (await _gitExitCode(['rev-parse', tagName]) == 0) {
    stderr.writeln('Tag $tagName 已存在');
    exit(1);
  }

  stdout.writeln(
    '==> 当前版本基线: ${currentBaseline.version} (${currentBaseline.source})',
  );
  stdout.writeln('==> 目标版本: $releaseVersion');
  stdout.writeln('==> pubspec 版本: $pubspecVersion');
  stdout.writeln('');
  stdout.writeln('==========================================');
  stdout.writeln('  发版信息');
  stdout.writeln('==========================================');
  stdout.writeln('版本命令: ${options.target}');
  stdout.writeln('发版通道: ${options.track.label}');
  stdout.writeln('Tag: $tagName');
  stdout.writeln('Release Version: $releaseVersion');
  stdout.writeln('Pubspec Version: $pubspecVersion');
  stdout.writeln('类型: ${isPrerelease ? '预发布版' : '稳定版'}');
  if (!isPrerelease) {
    // stable 的 GH Release / TG / AltStore 正文取自人工亮点文件,缺失时 CI
    // 自动回退全量 commit 明细(不挡发版),这里只提醒,由下方确认交互兜底
    final highlightsPath = 'highlights/$tagName.md';
    if (File(highlightsPath).existsSync()) {
      stdout.writeln('版本亮点: $highlightsPath');
    } else {
      stdout.writeln('版本亮点: 缺失($highlightsPath)');
      stdout.writeln('  警告: 发布日志将回退为全量 commit 明细,');
      stdout.writeln('  建议先用 /release-highlights 起草亮点并提交后再发版');
    }
  }
  stdout.writeln('分支: $currentBranch');
  if (currentBranch != 'main') {
    stdout.writeln('注意: 当前不在 main 分支');
  }
  if (options.dryRun) {
    stdout.writeln('模式: dry-run');
  }
  stdout.writeln('==========================================');
  stdout.writeln('');

  if (options.dryRun) {
    stdout.writeln('==> dry-run 模式，不执行写入与推送');
    return;
  }

  if (!options.yes &&
      (await _cliUi.confirm(prompt: '确认发版?', defaultValue: false) != true)) {
    stdout.writeln('==> 已取消');
    return;
  }

  await runOrExit(
    title: '执行发版前检查',
    executable: Platform.resolvedExecutable,
    arguments: [
      'tool/project_tasks.dart',
      'release:prepare',
      if (options.skipAnalyze) '--skip-analyze',
      if (options.skipTest) '--skip-test',
    ],
  );

  stdout.writeln('==> 更新 pubspec.yaml...');
  final updated = _replacePubspecVersion(
    pubspecFile.readAsStringSync(),
    version: pubspecVersion,
  );
  pubspecFile.writeAsStringSync(updated);

  await runOrExit(
    title: '提交版本号变更',
    executable: 'git',
    arguments: ['add', pubspecFile.path],
  );
  await runOrExit(
    title: '创建版本提交',
    executable: 'git',
    arguments: [
      'commit',
      '-m',
      'chore: bump version to $releaseVersion',
      '-m',
      'Co-Authored-By: Release Script <noreply@github.com>',
    ],
  );
  await runOrExit(
    title: '推送到远程仓库',
    executable: 'git',
    arguments: const ['push'],
  );
  await runOrExit(
    title: '创建标签 $tagName',
    executable: 'git',
    arguments: ['tag', '-a', tagName, '-m', 'Release $tagName'],
  );
  await runOrExit(
    title: '推送标签 $tagName',
    executable: 'git',
    arguments: ['push', 'origin', tagName],
  );

  stdout.writeln('');
  stdout.writeln('==========================================');
  stdout.writeln('发版成功');
  stdout.writeln('==========================================');
  stdout.writeln('Tag: $tagName');
  stdout.writeln(
    'GitHub Actions: https://github.com/Lingyan000/fluxdo/actions',
  );
  stdout.writeln('Releases: https://github.com/Lingyan000/fluxdo/releases');
  stdout.writeln('==========================================');
  stdout.writeln('');
  stdout.writeln(
    isPrerelease ? '这是预发布版，不会生成 Changelog' : '稳定版会自动生成 Changelog 并提交到 main 分支',
  );
}

Future<void> _assertGitRepository() async {
  if (await _gitExitCode(['rev-parse', '--git-dir']) == 0) {
    return;
  }
  stderr.writeln('当前目录不是 git 仓库');
  exit(1);
}

Future<void> _assertCleanGitTree() async {
  if (await _gitExitCode(['diff-index', '--quiet', 'HEAD', '--']) == 0) {
    return;
  }
  stderr.writeln('存在未提交的更改，请先提交或暂存');
  exit(1);
}

Future<int> _gitExitCode(List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    runInShell: Platform.isWindows,
    workingDirectory: workspaceRootPath,
  );
  return result.exitCode;
}

Future<String> _gitStdout(List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    runInShell: Platform.isWindows,
    workingDirectory: workspaceRootPath,
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr.toString().trim());
    exit(result.exitCode);
  }
  return result.stdout.toString().trim();
}

Future<_ReleaseOptions> _resolveReleaseOptions(
  _ReleaseOptions options,
  _SemVersion current,
) async {
  if (options.target != null) {
    return options;
  }

  final interactive = await _promptReleaseOptions(
    current,
    seedPreid: options.preid,
    initialDryRun: options.dryRun,
    track: options.track,
  );
  if (interactive != null) {
    return _ReleaseOptions(
      target: interactive.target,
      preid: interactive.preid,
      yes: options.yes,
      dryRun: interactive.dryRun,
      skipAnalyze: options.skipAnalyze,
      skipTest: options.skipTest,
      track: interactive.track,
      showHelp: false,
    );
  }

  if (_cliUi.canPrompt) {
    stdout.writeln('==> 已取消');
    exit(0);
  }

  stderr.writeln('未指定版本命令，且当前入口无法进入交互模式');
  stderr.writeln(_usage);
  exit(64);
}

_ReleaseOptions _parseArgs(List<String> args) {
  String? target;
  String? preid;
  var track = _ReleaseTrack.any;
  var yes = false;
  var dryRun = false;
  var skipAnalyze = false;
  var skipTest = false;
  var showHelp = false;

  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    switch (arg) {
      case '--help':
      case '-h':
        showHelp = true;
        continue;
      case '--yes':
      case '-y':
        yes = true;
        continue;
      case '--dry-run':
        dryRun = true;
        continue;
      case '--skip-analyze':
        skipAnalyze = true;
        continue;
      case '--skip-test':
        skipTest = true;
        continue;
      case '--track':
        if (index + 1 >= args.length) {
          stderr.writeln('--track 缺少值');
          exit(64);
        }
        track = _ReleaseTrackX.parseCli(args[++index]);
        continue;
      case '--pre':
        continue;
      case '--preid':
        if (index + 1 >= args.length) {
          stderr.writeln('--preid 缺少值');
          exit(64);
        }
        preid = args[++index].trim();
        continue;
      default:
        if (arg.startsWith('--track=')) {
          track = _ReleaseTrackX.parseCli(arg.substring('--track='.length));
          continue;
        }
        if (arg.startsWith('--preid=')) {
          preid = arg.substring('--preid='.length).trim();
          continue;
        }
        if (arg.startsWith('-')) {
          stderr.writeln('未知参数: $arg');
          exit(64);
        }
        target ??= arg.trim();
    }
  }

  return _ReleaseOptions(
    target: target,
    preid: preid == null || preid.isEmpty ? null : preid,
    yes: yes,
    dryRun: dryRun,
    skipAnalyze: skipAnalyze,
    skipTest: skipTest,
    track: track,
    showHelp: showHelp,
  );
}

String _readCurrentVersion(File pubspecFile) {
  final match = RegExp(
    r'^version:\s*(.+)$',
    multiLine: true,
  ).firstMatch(pubspecFile.readAsStringSync());
  if (match == null) {
    stderr.writeln('pubspec.yaml 缺少 version 字段');
    exit(1);
  }
  return match.group(1)!.split('+').first.trim();
}

Future<_VersionBaseline> _resolveCurrentBaseline(String pubspecVersion) async {
  final pubspecSemver = _SemVersion.parse(pubspecVersion);
  final latestTag = await _readLatestReleaseTag();
  if (latestTag == null) {
    return _VersionBaseline(pubspecSemver, 'pubspec.yaml');
  }

  if (latestTag.coreString == pubspecSemver.coreString) {
    return _VersionBaseline(latestTag, 'latest git tag');
  }

  return latestTag.compareCore(pubspecSemver) > 0
      ? _VersionBaseline(latestTag, 'latest git tag')
      : _VersionBaseline(pubspecSemver, 'pubspec.yaml');
}

Future<_SemVersion?> _readLatestReleaseTag() async {
  final result = await Process.run(
    'git',
    const ['tag', '--list', 'v*', '--sort=-v:refname'],
    runInShell: Platform.isWindows,
    workingDirectory: workspaceRootPath,
  );
  if (result.exitCode != 0) {
    return null;
  }

  final tags = result.stdout
      .toString()
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);

  for (final tag in tags) {
    final normalized = tag.startsWith('v') ? tag.substring(1) : tag;
    final version = _SemVersion.tryParse(normalized);
    if (version != null) {
      return version;
    }
  }
  return null;
}

_SemVersion _resolveTargetVersion({
  required String rawTarget,
  required _SemVersion current,
  String? preid,
  required _ReleaseTrack track,
}) {
  final normalizedTarget = rawTarget.startsWith('v')
      ? rawTarget.substring(1)
      : rawTarget;
  final bump = _ReleaseBumpX.tryParse(normalizedTarget, track: track);
  if (bump != null) {
    return _bumpVersion(current, bump, preid: preid);
  }

  if (!_versionPattern.hasMatch(normalizedTarget)) {
    stderr.writeln(
      '版本号格式错误，应为: x.y.z、x.y.z-beta，或 ${track.commandHint}',
    );
    exit(64);
  }

  final explicitVersion = _SemVersion.parse(normalizedTarget);
  _assertExplicitVersionMatchesTrack(explicitVersion, track);
  if (explicitVersion.compareTo(current) <= 0) {
    stderr.writeln('显式版本必须大于当前版本基线 ${current.toString()}');
    exit(64);
  }
  return explicitVersion;
}

void _assertExplicitVersionMatchesTrack(
  _SemVersion explicitVersion,
  _ReleaseTrack track,
) {
  if (track == _ReleaseTrack.release && explicitVersion.isPrerelease) {
    stderr.writeln('稳定版通道不接受预发布显式版本，请改用 prerelease 通道');
    exit(64);
  }
  if (track == _ReleaseTrack.prerelease && !explicitVersion.isPrerelease) {
    stderr.writeln('预发布通道需要显式预发布版本，例如 1.2.3-beta.0');
    exit(64);
  }
}

_SemVersion _bumpVersion(
  _SemVersion current,
  _ReleaseBump bump, {
  String? preid,
}) {
  final effectivePreid = preid?.trim().isNotEmpty == true
      ? preid!.trim()
      : null;

  switch (bump) {
    case _ReleaseBump.patch:
      if (current.isPrerelease) {
        return current.withoutPrerelease();
      }
      return current.copyWith(patch: current.patch + 1, prerelease: null);
    case _ReleaseBump.minor:
      if (current.isPrerelease && current.patch == 0) {
        return current.withoutPrerelease();
      }
      return _SemVersion(current.major, current.minor + 1, 0);
    case _ReleaseBump.major:
      if (current.isPrerelease && current.minor == 0 && current.patch == 0) {
        return current.withoutPrerelease();
      }
      return _SemVersion(current.major + 1, 0, 0);
    case _ReleaseBump.prepatch:
      return _SemVersion(
        current.major,
        current.minor,
        current.patch + 1,
        prerelease: _initialPrerelease(effectivePreid),
      );
    case _ReleaseBump.preminor:
      return _SemVersion(
        current.major,
        current.minor + 1,
        0,
        prerelease: _initialPrerelease(effectivePreid),
      );
    case _ReleaseBump.premajor:
      return _SemVersion(
        current.major + 1,
        0,
        0,
        prerelease: _initialPrerelease(effectivePreid),
      );
    case _ReleaseBump.next:
      if (!current.isPrerelease) {
        return _SemVersion(
          current.major,
          current.minor,
          current.patch + 1,
          prerelease: _initialPrerelease(effectivePreid),
        );
      }
      return _incrementPrerelease(current, preid: effectivePreid);
  }
}

String _initialPrerelease(String? preid) => '${preid ?? 'beta'}.0';

_SemVersion _incrementPrerelease(_SemVersion current, {String? preid}) {
  final info = current.prereleaseInfo;
  final desiredId = preid ?? info?.identifier ?? 'beta';
  if (info != null && info.identifier == desiredId && info.number != null) {
    final nextNumber = info.number! + 1;
    return current.copyWith(
      prerelease: _formatPrerelease(
        desiredId,
        nextNumber,
        style: info.style == _PrereleaseStyle.bare
            ? _PrereleaseStyle.dot
            : info.style,
      ),
    );
  }
  return current.copyWith(
    prerelease: _formatPrerelease(desiredId, 0, style: _PrereleaseStyle.dot),
  );
}

String _formatPrerelease(
  String id,
  int number, {
  required _PrereleaseStyle style,
}) {
  return switch (style) {
    _PrereleaseStyle.compact => '$id$number',
    _PrereleaseStyle.dot || _PrereleaseStyle.bare => '$id.$number',
  };
}

String _replacePubspecVersion(String content, {required String version}) {
  final updated = content.replaceFirst(
    RegExp(r'^version:.*$', multiLine: true),
    'version: $version',
  );
  if (updated == content) {
    stderr.writeln('更新 pubspec.yaml 版本失败');
    exit(1);
  }
  return updated;
}

String _buildVersionCode(DateTime now) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${twoDigits(now.month)}${twoDigits(now.day)}${twoDigits(now.hour)}';
}

Future<_InteractiveReleaseSelection?> _promptReleaseOptions(
  _SemVersion current, {
  String? seedPreid,
  required bool initialDryRun,
  required _ReleaseTrack track,
}) async {
  final selectedTrack = track == _ReleaseTrack.any
      ? await _promptReleaseTrack()
      : track;
  if (selectedTrack == null) {
    return null;
  }

  final defaultPreid = _defaultPreid(seedPreid, current);

  stdout.writeln('未指定版本命令，进入交互式发版。');
  stdout.writeln('直接回车使用默认项，输入 q 可取消。');
  stdout.writeln('');

  final target = await _promptReleaseTarget(
    current,
    track: selectedTrack,
    defaultPreid: defaultPreid,
  );
  if (target == null) {
    return null;
  }

  String? preid;
  if (_needsPreid(target, track: selectedTrack)) {
    preid = await _promptPreid(defaultPreid);
    if (preid == null) {
      return null;
    }
  }

  final dryRun = await _promptExecutionMode(initialDryRun: initialDryRun);
  if (dryRun == null) {
    return null;
  }

  return _InteractiveReleaseSelection(
    target: target,
    preid: preid,
    dryRun: dryRun,
    track: selectedTrack,
  );
}

String _defaultPreid(String? seedPreid, _SemVersion current) {
  final trimmed = seedPreid?.trim();
  if (trimmed != null && trimmed.isNotEmpty) {
    return trimmed;
  }
  return current.prereleaseInfo?.identifier ?? 'beta';
}

Future<String?> _promptReleaseTarget(
  _SemVersion current, {
  required _ReleaseTrack track,
  required String defaultPreid,
}) async {
  final options = switch (track) {
    _ReleaseTrack.release => <CliOption<String>>[
        CliOption(
          value: 'patch',
          label: 'patch',
          detail: '修复发布 -> ${_bumpVersion(current, _ReleaseBump.patch)}',
          aliases: const ['p'],
        ),
        CliOption(
          value: 'minor',
          label: 'minor',
          detail: '功能发布 -> ${_bumpVersion(current, _ReleaseBump.minor)}',
        ),
        CliOption(
          value: 'major',
          label: 'major',
          detail: '主版本发布 -> ${_bumpVersion(current, _ReleaseBump.major)}',
        ),
        const CliOption(
          value: '__custom__',
          label: 'custom',
          detail: '手动输入显式稳定版版本号',
          aliases: <String>['c'],
        ),
      ],
    _ReleaseTrack.prerelease => <CliOption<String>>[
        CliOption(
          value: 'patch',
          label: 'patch',
          detail:
              '开启补丁预发布 -> ${_bumpVersion(current, _ReleaseBump.prepatch, preid: defaultPreid)}',
          aliases: const ['p'],
        ),
        CliOption(
          value: 'minor',
          label: 'minor',
          detail:
              '开启次版本预发布 -> ${_bumpVersion(current, _ReleaseBump.preminor, preid: defaultPreid)}',
        ),
        CliOption(
          value: 'major',
          label: 'major',
          detail:
              '开启主版本预发布 -> ${_bumpVersion(current, _ReleaseBump.premajor, preid: defaultPreid)}',
        ),
        CliOption(
          value: 'next',
          label: 'next',
          detail:
              '推进当前预发布序列 -> ${_bumpVersion(current, _ReleaseBump.next, preid: defaultPreid)}',
          aliases: const ['n'],
        ),
        const CliOption(
          value: '__custom__',
          label: 'custom',
          detail: '手动输入显式预发布版本号',
          aliases: <String>['c'],
        ),
      ],
    _ReleaseTrack.any => throw StateError('unexpected any track in prompt'),
  };

  final selection = await _cliUi.select(
    title: track == _ReleaseTrack.release ? '选择稳定版类型' : '选择预发布类型',
    options: options,
  );
  if (selection == null) {
    return null;
  }
  if (selection != '__custom__') {
    return selection;
  }
  return _promptExplicitVersion(current);
}

Future<String?> _promptExplicitVersion(_SemVersion current) async {
  return _cliUi.input(
    prompt: '输入显式版本号',
    validator: (raw) {
      final normalized = raw.startsWith('v') ? raw.substring(1) : raw;
      if (!_versionPattern.hasMatch(normalized)) {
        return '版本号格式错误，应为 x.y.z 或 x.y.z-beta';
      }

      final explicitVersion = _SemVersion.tryParse(normalized);
      if (explicitVersion == null) {
        return '无法解析版本号: $raw';
      }
      if (explicitVersion.compareTo(current) <= 0) {
        return '显式版本必须大于当前版本基线 ${current.toString()}';
      }
      return null;
    },
  );
}

Future<_ReleaseTrack?> _promptReleaseTrack() {
  return _cliUi.select(
    title: '选择发版通道',
    options: const [
      CliOption(
        value: _ReleaseTrack.release,
        label: 'release',
        detail: '稳定版发版',
        aliases: <String>['r'],
      ),
      CliOption(
        value: _ReleaseTrack.prerelease,
        label: 'prerelease',
        detail: '预发布发版',
        aliases: <String>['p'],
      ),
    ],
  );
}

bool _needsPreid(String target, {required _ReleaseTrack track}) {
  return switch (_ReleaseBumpX.tryParse(target, track: track)) {
    _ReleaseBump.prepatch ||
    _ReleaseBump.preminor ||
    _ReleaseBump.premajor ||
    _ReleaseBump.next => true,
    _ => false,
  };
}

Future<String?> _promptPreid(String defaultPreid) async {
  final options = <CliOption<String>>[
    CliOption(
      value: defaultPreid,
      label: defaultPreid,
      detail: '使用当前默认预发布标识',
    ),
    const CliOption(
      value: '__custom__',
      label: 'custom',
      detail: '手动输入预发布标识',
      aliases: <String>['c'],
    ),
  ];
  if (defaultPreid != 'beta') {
    options.insert(
      options.length - 1,
      const CliOption(
        value: 'beta',
        label: 'beta',
        detail: '默认预发布序列',
      ),
    );
  }
  if (defaultPreid != 'rc') {
    options.insert(
      options.length - 1,
      const CliOption(
        value: 'rc',
        label: 'rc',
        detail: '候选发布序列',
      ),
    );
  }
  if (defaultPreid != 'alpha') {
    options.insert(
      options.length - 1,
      const CliOption(
        value: 'alpha',
        label: 'alpha',
        detail: '早期验证序列',
      ),
    );
  }

  final selection = await _cliUi.select(
    title: '选择预发布标识',
    options: options,
  );
  if (selection == null) {
    return null;
  }
  if (selection != '__custom__') {
    return selection;
  }

  return _cliUi.input(prompt: '输入预发布标识');
}

Future<bool?> _promptExecutionMode({required bool initialDryRun}) async {
  final selection = await _cliUi.select(
    title: '选择执行模式',
    defaultIndex: initialDryRun ? 1 : 0,
    options: const [
      CliOption(
        value: false,
        label: 'release',
        detail: '正式执行写入、提交、推送与打 tag',
        aliases: <String>['r'],
      ),
      CliOption(
        value: true,
        label: 'dry-run',
        detail: '只计算版本并打印结果',
        aliases: <String>['d', 'dry'],
      ),
    ],
  );
  return selection;
}

const _usage = '''
用法:
  dart tool/release.dart [版本号|releaseType] [选项]

示例:
  dart tool/release.dart
  dart tool/release.dart patch
  dart tool/release.dart minor -y
  dart tool/release.dart --track prerelease next --preid beta
  dart tool/release.dart --track prerelease patch --preid rc
  dart tool/release.dart 0.1.0
  dart tool/release.dart 0.1.0-beta

releaseType:
  patch | minor | major
  next

通道:
  --track release      稳定版通道，只接受 patch/minor/major 或稳定版显式版本
  --track prerelease   预发布通道，接受 patch/minor/major/next 或预发布显式版本
                       未指定时为兼容模式，同时接受旧的 prepatch/preminor/premajor/prerelease

选项:
  --preid <id>   指定预发布标识，默认 beta
  -y, --yes      跳过最终确认
  --dry-run      只计算版本并打印，不执行写入和推送
  --skip-analyze 跳过 flutter analyze
  --skip-test    跳过 flutter test

不传版本参数时:
  进入交互式选择流程
''';

class _ReleaseOptions {
  const _ReleaseOptions({
    required this.target,
    required this.preid,
    required this.yes,
    required this.dryRun,
    required this.skipAnalyze,
    required this.skipTest,
    required this.track,
    required this.showHelp,
  });

  final String? target;
  final String? preid;
  final bool yes;
  final bool dryRun;
  final bool skipAnalyze;
  final bool skipTest;
  final _ReleaseTrack track;
  final bool showHelp;
}

class _VersionBaseline {
  const _VersionBaseline(this.version, this.source);

  final _SemVersion version;
  final String source;
}

class _InteractiveReleaseSelection {
  const _InteractiveReleaseSelection({
    required this.target,
    required this.preid,
    required this.dryRun,
    required this.track,
  });

  final String target;
  final String? preid;
  final bool dryRun;
  final _ReleaseTrack track;
}

enum _ReleaseBump {
  patch,
  minor,
  major,
  prepatch,
  preminor,
  premajor,
  next,
}

extension _ReleaseBumpX on _ReleaseBump {
  static _ReleaseBump? tryParse(String value, {required _ReleaseTrack track}) {
    return switch (track) {
      _ReleaseTrack.release => switch (value) {
          'patch' => _ReleaseBump.patch,
          'minor' => _ReleaseBump.minor,
          'major' => _ReleaseBump.major,
          _ => null,
        },
      _ReleaseTrack.prerelease => switch (value) {
          'patch' || 'prepatch' => _ReleaseBump.prepatch,
          'minor' || 'preminor' => _ReleaseBump.preminor,
          'major' || 'premajor' => _ReleaseBump.premajor,
          'next' || 'prerelease' => _ReleaseBump.next,
          _ => null,
        },
      _ReleaseTrack.any => switch (value) {
          'patch' => _ReleaseBump.patch,
          'minor' => _ReleaseBump.minor,
          'major' => _ReleaseBump.major,
          'prepatch' => _ReleaseBump.prepatch,
          'preminor' => _ReleaseBump.preminor,
          'premajor' => _ReleaseBump.premajor,
          'next' || 'prerelease' => _ReleaseBump.next,
          _ => null,
        },
    };
  }
}

enum _ReleaseTrack { any, release, prerelease }

extension _ReleaseTrackX on _ReleaseTrack {
  String get label {
    return switch (this) {
      _ReleaseTrack.any => '兼容模式',
      _ReleaseTrack.release => '稳定版',
      _ReleaseTrack.prerelease => '预发布',
    };
  }

  String get commandHint {
    return switch (this) {
      _ReleaseTrack.any =>
        'patch/minor/major、prepatch/preminor/premajor/prerelease/next 等命令',
      _ReleaseTrack.release => 'patch/minor/major 等稳定版命令',
      _ReleaseTrack.prerelease => 'patch/minor/major/next 等预发布命令',
    };
  }

  static _ReleaseTrack parseCli(String value) {
    return switch (value.trim().toLowerCase()) {
      'any' => _ReleaseTrack.any,
      'release' => _ReleaseTrack.release,
      'prerelease' => _ReleaseTrack.prerelease,
      _ => _invalidTrack(value),
    };
  }
}

Never _invalidTrack(String value) {
  stderr.writeln('未知通道: $value，可选值为 release / prerelease / any');
  exit(64);
}

enum _PrereleaseStyle { dot, compact, bare }

class _PrereleaseInfo {
  const _PrereleaseInfo({
    required this.identifier,
    required this.number,
    required this.style,
  });

  final String identifier;
  final int? number;
  final _PrereleaseStyle style;
}

class _SemVersion implements Comparable<_SemVersion> {
  const _SemVersion(this.major, this.minor, this.patch, {this.prerelease});

  factory _SemVersion.parse(String input) {
    final version = tryParse(input);
    if (version == null) {
      stderr.writeln('无法解析版本号: $input');
      exit(64);
    }
    return version;
  }

  static _SemVersion? tryParse(String input) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
    ).firstMatch(input);
    if (match == null) {
      return null;
    }
    return _SemVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      prerelease: match.group(4),
    );
  }

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;

  bool get isPrerelease => prerelease != null && prerelease!.isNotEmpty;
  String get coreString => '$major.$minor.$patch';

  _PrereleaseInfo? get prereleaseInfo {
    final value = prerelease;
    if (value == null || value.isEmpty) {
      return null;
    }

    final dotMatch = RegExp(r'^([0-9A-Za-z-]+)\.(\d+)$').firstMatch(value);
    if (dotMatch != null) {
      return _PrereleaseInfo(
        identifier: dotMatch.group(1)!,
        number: int.parse(dotMatch.group(2)!),
        style: _PrereleaseStyle.dot,
      );
    }

    final compactMatch = RegExp(r'^([A-Za-z-]+)(\d+)$').firstMatch(value);
    if (compactMatch != null) {
      return _PrereleaseInfo(
        identifier: compactMatch.group(1)!,
        number: int.parse(compactMatch.group(2)!),
        style: _PrereleaseStyle.compact,
      );
    }

    return _PrereleaseInfo(
      identifier: value,
      number: null,
      style: _PrereleaseStyle.bare,
    );
  }

  int compareCore(_SemVersion other) {
    if (major != other.major) {
      return major.compareTo(other.major);
    }
    if (minor != other.minor) {
      return minor.compareTo(other.minor);
    }
    return patch.compareTo(other.patch);
  }

  _SemVersion withoutPrerelease() => _SemVersion(major, minor, patch);

  _SemVersion copyWith({
    int? major,
    int? minor,
    int? patch,
    String? prerelease,
  }) {
    return _SemVersion(
      major ?? this.major,
      minor ?? this.minor,
      patch ?? this.patch,
      prerelease: prerelease,
    );
  }

  @override
  int compareTo(_SemVersion other) {
    final core = compareCore(other);
    if (core != 0) {
      return core;
    }

    final left = prerelease;
    final right = other.prerelease;
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return 1;
    }
    if (right == null) {
      return -1;
    }

    final leftParts = left.split('.');
    final rightParts = right.split('.');
    final maxLength = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < maxLength; index++) {
      if (index >= leftParts.length) {
        return -1;
      }
      if (index >= rightParts.length) {
        return 1;
      }

      final leftPart = leftParts[index];
      final rightPart = rightParts[index];
      final leftNumber = int.tryParse(leftPart);
      final rightNumber = int.tryParse(rightPart);
      if (leftNumber != null && rightNumber != null) {
        if (leftNumber != rightNumber) {
          return leftNumber.compareTo(rightNumber);
        }
        continue;
      }
      if (leftNumber != null) {
        return -1;
      }
      if (rightNumber != null) {
        return 1;
      }
      if (leftPart != rightPart) {
        return leftPart.compareTo(rightPart);
      }
    }

    return 0;
  }

  @override
  String toString() =>
      prerelease == null ? coreString : '$coreString-$prerelease';
}
