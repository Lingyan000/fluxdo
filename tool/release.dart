import 'dart:io';

import '_cli_ui.dart';
import '_workspace_cli.dart';

final _versionPattern = RegExp(r'^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$');
final _cliUi = CliUi();

Future<void> Function(List<String> prepareArgs)? _releasePrepareHandler;

Future<void> main(List<String> args) async {
  await runRelease(args);
}

Future<void> runRelease(
  List<String> args, {
  Future<void> Function(List<String> prepareArgs)? onReleasePrepare,
}) async {
  enterWorkspaceRoot();
  _releasePrepareHandler = onReleasePrepare;

  var options = _parseArgs(args);
  if (options.showHelp) {
    stdout.writeln(_usage);
    return;
  }

  final pubspecFile = File('pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    _cliUi.error('找不到 pubspec.yaml 文件');
    exit(1);
  }

  await _assertGitRepository();

  final currentVersion = _readCurrentVersion(pubspecFile);
  final currentBaseline = await _resolveCurrentBaseline(currentVersion);
  final currentBranch = await _gitStdout(['branch', '--show-current']);
  final gitStatus = await _inspectGitStatus();
  final recentCommits = await _readCommitsSinceLatestTag(currentBaseline.latestTagName);

  _cliUi.intro(
    'FluxDO Release',
    subtitle:
        '分支 $currentBranch · 基线 ${currentBaseline.version} (${currentBaseline.source})',
  );

  // 展示距上一个 tag 的提交概览，方便决定发 patch 还是 minor。
  _printRecentCommits(currentBaseline.latestTagName, recentCommits);

  // 提前告知工作区状态，避免交互选完所有步骤才报错。
  if (gitStatus.hasTrackedChanges) {
    if (!options.dryRun && (options.target != null && options.yes)) {
      _printDirtyTreeError(gitStatus);
      exit(1);
    }
    _cliUi.warn(
      '工作区存在 ${gitStatus.trackedFiles.length} 个未提交改动（正式发版前需提交或暂存，可先 dry-run 预览）',
    );
    for (final file in gitStatus.trackedFiles.take(5)) {
      _cliUi.info(_cliUi.dim(file));
    }
    if (gitStatus.trackedFiles.length > 5) {
      _cliUi.info(_cliUi.dim('... 另有 ${gitStatus.trackedFiles.length - 5} 个文件'));
    }
    stdout.writeln('');
  } else if (gitStatus.untrackedFiles.isNotEmpty) {
    _cliUi.info(
      _cliUi.dim(
        '提示：工作区有 ${gitStatus.untrackedFiles.length} 个未跟踪文件（不影响本次发版）',
      ),
    );
    stdout.writeln('');
  }

  final isInteractive = options.target == null;

  while (true) {
    final resolved = await _resolveReleaseOptions(
      options,
      currentBaseline.version,
    );

    final targetVersion = _resolveTargetVersion(
      rawTarget: resolved.target!,
      current: currentBaseline.version,
      preid: resolved.preid,
      track: resolved.track,
    );
    final isPrerelease = targetVersion.isPrerelease;
    final releaseVersion = targetVersion.toString();
    final pubspecVersion = '$releaseVersion+${_buildVersionCode(DateTime.now())}';
    final tagName = 'v$releaseVersion';

    if (await _gitExitCode(['rev-parse', tagName]) == 0) {
      _cliUi.error('Tag $tagName 已存在');
      if (isInteractive && _cliUi.canPrompt) {
        stdout.writeln('');
        continue;
      }
      exit(1);
    }

    final highlightsPath = 'highlights/$tagName.md';
    final hasHighlights = !isPrerelease && File(highlightsPath).existsSync();
    final notes = <String>[
      if (currentBranch != 'main') '当前不在 main 分支（当前：$currentBranch）',
      if (!isPrerelease && !hasHighlights)
        '缺少亮点文件 $highlightsPath，发布日志将回退为全量 commit 明细（可用 /release-highlights 起草）',
      if (gitStatus.hasTrackedChanges && !resolved.dryRun)
        '工作区存在未提交改动，仅支持 dry-run，清理后再正式发版',
    ];

    final testScope = resolved.fullTest ? '全量测试' : '架构守卫';
    final checkLabel = resolved.skipAnalyze && resolved.skipTest
        ? '跳过 analyze 与测试（仍保留生成物校验）'
        : resolved.skipAnalyze
        ? '仅运行$testScope（跳过 analyze）'
        : resolved.skipTest
        ? '仅运行 analyze（跳过测试）'
        : resolved.fullTest
        ? '全量检查（analyze + 全量测试）'
        : '快速检查（analyze + 架构守卫 + 产物校验）';

    stdout.writeln('');
    _cliUi.summaryBox(
      title: resolved.dryRun ? '发版预览 (dry-run)' : '发版计划',
      isWarning: notes.isNotEmpty,
      rows: [
        CliSummaryRow(
          '版本变更',
          '${currentBaseline.version}  →  $releaseVersion',
          highlight: true,
        ),
        CliSummaryRow('Git Tag', tagName, highlight: true),
        CliSummaryRow('Pubspec', pubspecVersion),
        CliSummaryRow(
          '通道类型',
          '${resolved.track.label} · ${isPrerelease ? '预发布版' : '稳定版'}',
        ),
        CliSummaryRow('当前分支', currentBranch, warning: currentBranch != 'main'),
        if (!isPrerelease)
          CliSummaryRow(
            '版本亮点',
            hasHighlights ? highlightsPath : '缺失（将回退 commit 明细）',
            warning: !hasHighlights,
          ),
        CliSummaryRow('发版检查', checkLabel, dim: resolved.skipAnalyze && resolved.skipTest),
        CliSummaryRow('包含提交', '${recentCommits.totalCount} 条'),
      ],
      notes: notes,
    );
    stdout.writeln('');

    if (resolved.dryRun) {
      _cliUi.outro('dry-run 预览完成，未执行写入、提交与推送');
      return;
    }

    var effectiveSkipAnalyze = resolved.skipAnalyze;
    var effectiveSkipTest = resolved.skipTest;

    if (!resolved.yes) {
      if (!_cliUi.canPrompt) {
        _cliUi.error('当前入口无法进行交互确认，请追加 -y/--yes 或 --dry-run');
        exit(64);
      }

      final action = await _promptConfirmAction(
        dirtyTree: gitStatus.hasTrackedChanges,
        alreadySkippingChecks: effectiveSkipAnalyze && effectiveSkipTest,
        fullTest: resolved.fullTest,
        allowReselect: isInteractive,
      );
      switch (action) {
        case _ConfirmAction.release:
          break;
        case _ConfirmAction.fastRelease:
          effectiveSkipAnalyze = true;
          effectiveSkipTest = true;
          break;
        case _ConfirmAction.dryRun:
          _cliUi.outro('dry-run 预览完成，未执行写入、提交与推送');
          return;
        case _ConfirmAction.reselect:
          stdout.writeln('');
          continue;
        case _ConfirmAction.cancel:
        case null:
          _cliUi.cancel('已取消发版');
          return;
      }
    }

    if (gitStatus.hasTrackedChanges) {
      _printDirtyTreeError(gitStatus);
      exit(1);
    }

    await _executeRelease(
      pubspecFile: pubspecFile,
      pubspecVersion: pubspecVersion,
      releaseVersion: releaseVersion,
      tagName: tagName,
      isPrerelease: isPrerelease,
      skipAnalyze: effectiveSkipAnalyze,
      skipTest: effectiveSkipTest,
      fullTest: resolved.fullTest,
    );
    return;
  }
}

Future<void> _executeRelease({
  required File pubspecFile,
  required String pubspecVersion,
  required String releaseVersion,
  required String tagName,
  required bool isPrerelease,
  required bool skipAnalyze,
  required bool skipTest,
  required bool fullTest,
}) async {
  final totalWatch = Stopwatch()..start();

  await _runTimedStep('[1/5] 发版前检查', () async {
    final prepareArgs = <String>[
      'release:prepare',
      if (skipAnalyze) '--skip-analyze',
      if (skipTest) '--skip-test',
      if (fullTest) '--full-test',
    ];
    final handler = _releasePrepareHandler;
    if (handler != null) {
      await handler(prepareArgs);
      return;
    }
    await runOrExit(
      title: '执行发版前检查',
      executable: Platform.resolvedExecutable,
      arguments: ['tool/project_tasks.dart', ...prepareArgs],
    );
  });

  await _runTimedStep('[2/5] 更新 pubspec.yaml -> $pubspecVersion', () async {
    final updated = _replacePubspecVersion(
      pubspecFile.readAsStringSync(),
      version: pubspecVersion,
    );
    pubspecFile.writeAsStringSync(updated);
  });

  await _runTimedStep('[3/5] 创建版本提交并推送远端', () async {
    await runOrExit(
      title: '暂存 pubspec.yaml',
      executable: 'git',
      arguments: ['add', pubspecFile.path],
    );
    await runOrExit(
      title: '创建版本提交',
      executable: 'git',
      arguments: ['commit', '-m', 'chore(release): 发布 $releaseVersion'],
    );
    await runOrExit(
      title: '推送到远程仓库',
      executable: 'git',
      arguments: const ['push'],
    );
  });

  await _runTimedStep('[4/5] 创建标签 $tagName', () async {
    await runOrExit(
      title: '创建标签 $tagName',
      executable: 'git',
      arguments: ['tag', '-a', tagName, '-m', 'Release $tagName'],
    );
  });

  await _runTimedStep('[5/5] 推送标签 $tagName', () async {
    await runOrExit(
      title: '推送标签 $tagName',
      executable: 'git',
      arguments: ['push', 'origin', tagName],
    );
  });

  totalWatch.stop();
  stdout.writeln('');
  _cliUi.summaryBox(
    title: '发版成功',
    isSuccess: true,
    rows: [
      CliSummaryRow('Tag', tagName, highlight: true),
      CliSummaryRow('版本', pubspecVersion),
      CliSummaryRow('总耗时', _formatElapsed(totalWatch.elapsed)),
      const CliSummaryRow(
        'Actions',
        'https://github.com/Lingyan000/fluxdo/actions',
      ),
      const CliSummaryRow(
        'Releases',
        'https://github.com/Lingyan000/fluxdo/releases',
      ),
      CliSummaryRow(
        'Changelog',
        isPrerelease
            ? '预发布版，不生成 Changelog'
            : '稳定版将由 CI 自动生成 Changelog 并提交到 main',
        dim: true,
      ),
    ],
  );
  stdout.writeln('');
}

Future<void> _runTimedStep(
  String label,
  Future<void> Function() action,
) async {
  _cliUi.step(label);
  final watch = Stopwatch()..start();
  await action();
  watch.stop();
  _cliUi.success('$label ${_cliUi.dim('(${_formatElapsed(watch.elapsed)})')}');
}

String _formatElapsed(Duration duration) {
  if (duration.inMilliseconds < 1000) {
    return '${duration.inMilliseconds}ms';
  }
  return '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

void _printRecentCommits(String? latestTagName, _CommitSummary summary) {
  if (summary.totalCount == 0) {
    _cliUi.info(
      _cliUi.dim(
        latestTagName == null
            ? '暂无提交记录'
            : '自 $latestTagName 以来没有新提交',
      ),
    );
    stdout.writeln('');
    return;
  }

  final rangeText = latestTagName == null
      ? '最近提交（共 ${summary.totalCount} 条）'
      : '自 $latestTagName 以来新增 ${summary.totalCount} 条提交';
  _cliUi.info(_cliUi.boldWhite(rangeText));
  for (final line in summary.samples) {
    _cliUi.info(_cliUi.dim('  $line'));
  }
  if (summary.totalCount > summary.samples.length) {
    _cliUi.info(
      _cliUi.dim('  ... 另有 ${summary.totalCount - summary.samples.length} 条'),
    );
  }
  stdout.writeln('');
}

void _printDirtyTreeError(_GitWorkingTreeStatus status) {
  _cliUi.error('存在未提交的已跟踪更改，请先提交或暂存后再发版：');
  for (final file in status.trackedFiles.take(10)) {
    stderr.writeln('  $file');
  }
  if (status.trackedFiles.length > 10) {
    stderr.writeln('  ... 另有 ${status.trackedFiles.length - 10} 个文件');
  }
}

Future<void> _assertGitRepository() async {
  if (await _gitExitCode(['rev-parse', '--git-dir']) == 0) {
    return;
  }
  _cliUi.error('当前目录不是 git 仓库');
  exit(1);
}

Future<_GitWorkingTreeStatus> _inspectGitStatus() async {
  final result = await Process.run(
    'git',
    const ['status', '--porcelain'],
    runInShell: Platform.isWindows,
    workingDirectory: workspaceRootPath,
  );
  if (result.exitCode != 0) {
    return const _GitWorkingTreeStatus(trackedFiles: [], untrackedFiles: []);
  }
  final tracked = <String>[];
  final untracked = <String>[];
  for (final rawLine in result.stdout.toString().split(RegExp(r'\r?\n'))) {
    if (rawLine.length < 3) continue;
    if (rawLine.startsWith('?? ')) {
      untracked.add(rawLine.substring(3).trim());
    } else {
      tracked.add(rawLine.trim());
    }
  }
  return _GitWorkingTreeStatus(trackedFiles: tracked, untrackedFiles: untracked);
}

Future<_CommitSummary> _readCommitsSinceLatestTag(String? latestTagName) async {
  final rangeArgs = latestTagName == null
      ? const ['log', '--oneline', '--no-merges', '-n', '20']
      : ['log', '--oneline', '--no-merges', '$latestTagName..HEAD'];
  final result = await Process.run(
    'git',
    rangeArgs,
    runInShell: Platform.isWindows,
    workingDirectory: workspaceRootPath,
  );
  if (result.exitCode != 0) {
    return const _CommitSummary(totalCount: 0, samples: []);
  }
  final lines = result.stdout
      .toString()
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return _CommitSummary(
    totalCount: lines.length,
    samples: lines.take(5).toList(),
  );
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
      fullTest: options.fullTest,
      track: interactive.track,
      showHelp: false,
    );
  }

  if (_cliUi.canPrompt) {
    _cliUi.cancel('已取消发版');
    exit(0);
  }

  _cliUi.error('未指定版本命令，且当前入口无法进入交互模式');
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
  var fullTest = false;
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
      case '--full-test':
        fullTest = true;
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
    fullTest: fullTest,
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
    _cliUi.error('pubspec.yaml 缺少 version 字段');
    exit(1);
  }
  return match.group(1)!.split('+').first.trim();
}

Future<_VersionBaseline> _resolveCurrentBaseline(String pubspecVersion) async {
  final pubspecSemver = _SemVersion.parse(pubspecVersion);
  final latestTag = await _readLatestReleaseTag();
  if (latestTag == null) {
    return _VersionBaseline(pubspecSemver, 'pubspec.yaml', latestTagName: null);
  }

  final tagName = 'v${latestTag.toString()}';
  if (latestTag.coreString == pubspecSemver.coreString) {
    return _VersionBaseline(latestTag, 'latest git tag', latestTagName: tagName);
  }

  return latestTag.compareCore(pubspecSemver) > 0
      ? _VersionBaseline(latestTag, 'latest git tag', latestTagName: tagName)
      : _VersionBaseline(pubspecSemver, 'pubspec.yaml', latestTagName: tagName);
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
    _cliUi.error('版本号格式错误，应为: x.y.z、x.y.z-beta，或 ${track.commandHint}');
    exit(64);
  }

  final explicitVersion = _SemVersion.parse(normalizedTarget);
  _assertExplicitVersionMatchesTrack(explicitVersion, track);
  if (explicitVersion.compareTo(current) <= 0) {
    _cliUi.error('显式版本必须大于当前版本基线 ${current.toString()}');
    exit(64);
  }
  return explicitVersion;
}

void _assertExplicitVersionMatchesTrack(
  _SemVersion explicitVersion,
  _ReleaseTrack track,
) {
  if (track == _ReleaseTrack.release && explicitVersion.isPrerelease) {
    _cliUi.error('稳定版通道不接受预发布显式版本，请改用 prerelease 通道');
    exit(64);
  }
  if (track == _ReleaseTrack.prerelease && !explicitVersion.isPrerelease) {
    _cliUi.error('预发布通道需要显式预发布版本，例如 1.2.3-beta.0');
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
    _cliUi.error('更新 pubspec.yaml 版本失败');
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
      ? await _promptReleaseTrack(current)
      : track;
  if (selectedTrack == null) {
    return null;
  }

  final defaultPreid = _defaultPreid(seedPreid, current);

  final target = await _promptReleaseTarget(
    current,
    track: selectedTrack,
    defaultPreid: defaultPreid,
  );
  if (target == null) {
    return null;
  }

  String? preid = seedPreid;
  if (preid == null && _needsPreid(target, track: selectedTrack)) {
    preid = await _promptPreid(current, target, defaultPreid);
    if (preid == null) {
      return null;
    }
  }

  return _InteractiveReleaseSelection(
    target: target,
    preid: preid,
    dryRun: initialDryRun,
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
          detail: current.isPrerelease
              ? '从预发布转正 · $current → ${_bumpVersion(current, _ReleaseBump.patch)}'
              : '修复发布 · $current → ${_bumpVersion(current, _ReleaseBump.patch)}',
          aliases: const ['p'],
          badge: '默认',
        ),
        CliOption(
          value: 'minor',
          label: 'minor',
          detail:
              '功能发布 · $current → ${_bumpVersion(current, _ReleaseBump.minor)}',
          aliases: const ['m'],
        ),
        CliOption(
          value: 'major',
          label: 'major',
          detail:
              '主版本发布 · $current → ${_bumpVersion(current, _ReleaseBump.major)}',
        ),
        const CliOption(
          value: '__custom__',
          label: 'custom',
          detail: '手动输入显式稳定版版本号',
          aliases: <String>['c'],
        ),
      ],
    _ReleaseTrack.prerelease => <CliOption<String>>[
        if (current.isPrerelease)
          CliOption(
            value: 'next',
            label: 'next',
            detail:
                '推进当前预发布 · $current → ${_bumpVersion(current, _ReleaseBump.next, preid: defaultPreid)}',
            aliases: const ['n'],
            badge: '推荐',
          ),
        CliOption(
          value: 'patch',
          label: 'patch',
          detail:
              '补丁预发布 · $current → ${_bumpVersion(current, _ReleaseBump.prepatch, preid: defaultPreid)}',
          aliases: const ['p'],
          badge: current.isPrerelease ? null : '默认',
        ),
        CliOption(
          value: 'minor',
          label: 'minor',
          detail:
              '次版本预发布 · $current → ${_bumpVersion(current, _ReleaseBump.preminor, preid: defaultPreid)}',
          aliases: const ['m'],
        ),
        CliOption(
          value: 'major',
          label: 'major',
          detail:
              '主版本预发布 · $current → ${_bumpVersion(current, _ReleaseBump.premajor, preid: defaultPreid)}',
        ),
        if (!current.isPrerelease)
          CliOption(
            value: 'next',
            label: 'next',
            detail:
                '推进预发布序列 · $current → ${_bumpVersion(current, _ReleaseBump.next, preid: defaultPreid)}',
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
  return _promptExplicitVersion(current, track: track);
}

Future<String?> _promptExplicitVersion(
  _SemVersion current, {
  required _ReleaseTrack track,
}) async {
  final example = track == _ReleaseTrack.prerelease
      ? '${_bumpVersion(current, _ReleaseBump.prepatch, preid: 'beta')}'
      : '${_bumpVersion(current, _ReleaseBump.patch)}';
  return _cliUi.input(
    prompt: '输入显式版本号',
    placeholder: '大于 $current，例如 $example',
    validator: (raw) {
      final normalized = raw.startsWith('v') ? raw.substring(1) : raw;
      if (!_versionPattern.hasMatch(normalized)) {
        return '版本号格式错误，应为 x.y.z 或 x.y.z-beta.0';
      }

      final explicitVersion = _SemVersion.tryParse(normalized);
      if (explicitVersion == null) {
        return '无法解析版本号: $raw';
      }
      if (track == _ReleaseTrack.release && explicitVersion.isPrerelease) {
        return '稳定版通道不接受预发布版本，请输入 x.y.z';
      }
      if (track == _ReleaseTrack.prerelease && !explicitVersion.isPrerelease) {
        return '预发布通道需要带预发布后缀，例如 $example';
      }
      if (explicitVersion.compareTo(current) <= 0) {
        return '显式版本必须大于当前版本基线 ${current.toString()}';
      }
      return null;
    },
  );
}

Future<_ReleaseTrack?> _promptReleaseTrack(_SemVersion current) {
  return _cliUi.select(
    title: '选择发版通道',
    defaultIndex: current.isPrerelease ? 1 : 0,
    options: [
      CliOption(
        value: _ReleaseTrack.release,
        label: 'release',
        detail: current.isPrerelease
            ? '正式版通道（可从 $current 转正）'
            : '正式版通道（生成 Changelog 与全量分发）',
        aliases: const ['r'],
      ),
      CliOption(
        value: _ReleaseTrack.prerelease,
        label: 'prerelease',
        detail: '预发布通道（Beta / RC 测试版）',
        aliases: const ['p'],
        badge: current.isPrerelease ? '当前' : null,
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

Future<String?> _promptPreid(
  _SemVersion current,
  String target,
  String defaultPreid,
) async {
  final bump = _ReleaseBumpX.tryParse(target, track: _ReleaseTrack.prerelease)!;

  String previewFor(String id) => '→ ${_bumpVersion(current, bump, preid: id)}';

  final orderedIds = <String>[
    defaultPreid,
    for (final candidate in const ['beta', 'rc', 'alpha'])
      if (candidate != defaultPreid) candidate,
  ];

  final options = <CliOption<String>>[
    for (final id in orderedIds)
      CliOption(
        value: id,
        label: id,
        detail: '${_preidDescription(id)} ${previewFor(id)}',
        badge: id == defaultPreid ? '默认' : null,
      ),
    const CliOption(
      value: '__custom__',
      label: 'custom',
      detail: '手动输入自定义预发布标识',
      aliases: <String>['c'],
    ),
  ];

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

  return _cliUi.input(
    prompt: '输入预发布标识',
    placeholder: '如 beta / rc / dev',
    validator: (raw) {
      if (!RegExp(r'^[0-9A-Za-z-]+$').hasMatch(raw)) {
        return '标识只能包含字母、数字和连字符';
      }
      return null;
    },
  );
}

String _preidDescription(String id) {
  return switch (id) {
    'beta' => '常规公测序列',
    'rc' => '发版候选序列',
    'alpha' => '早期内部验证',
    _ => '自定义预发布标识',
  };
}

Future<_ConfirmAction?> _promptConfirmAction({
  required bool dirtyTree,
  required bool alreadySkippingChecks,
  required bool fullTest,
  required bool allowReselect,
}) {
  final options = <CliOption<_ConfirmAction>>[
    if (dirtyTree)
      const CliOption(
        value: _ConfirmAction.dryRun,
        label: 'dry-run',
        detail: '仅预览（当前工作区有未提交改动）',
        aliases: <String>['d'],
        badge: '推荐',
      ),
    if (!dirtyTree)
      CliOption(
        value: _ConfirmAction.release,
        label: 'release',
        detail: alreadySkippingChecks
            ? '确认执行写入、提交、推送与打 tag'
            : fullTest
            ? '执行全量检查（analyze + 全量测试）并推送 tag'
            : '执行快速检查（analyze + 架构守卫）并推送 tag',
        aliases: const ['y', 'r'],
        badge: '推荐',
      ),
    if (!dirtyTree && !alreadySkippingChecks)
      const CliOption(
        value: _ConfirmAction.fastRelease,
        label: 'fast',
        detail: '跳过 analyze 与测试，直接提交并推送 tag',
        aliases: <String>['f'],
      ),
    if (!dirtyTree)
      const CliOption(
        value: _ConfirmAction.dryRun,
        label: 'dry-run',
        detail: '仅预览结果，不写入也不推送',
        aliases: <String>['d'],
      ),
    if (allowReselect)
      const CliOption(
        value: _ConfirmAction.reselect,
        label: 'reselect',
        detail: '返回重新选择版本或通道',
        aliases: <String>['b'],
      ),
    const CliOption(
      value: _ConfirmAction.cancel,
      label: 'cancel',
      detail: '取消本次发版',
      aliases: <String>['n'],
    ),
  ];

  return _cliUi.select(
    title: '下一步操作',
    options: options,
  );
}

const _usage = '''
用法:
  mise r release [版本号|releaseType] [选项]
  dart tool/release.dart [版本号|releaseType] [选项]

示例:
  mise r release
  mise r release patch
  mise r release minor -y
  mise r prerelease next --preid beta
  mise r prerelease patch --preid rc
  mise r release 0.1.0
  mise r prerelease 0.1.0-beta.0

releaseType:
  patch | minor | major | next

通道:
  --track release      稳定版通道，只接受 patch/minor/major 或稳定版显式版本
  --track prerelease   预发布通道，接受 patch/minor/major/next 或预发布显式版本
                       未指定时进入交互选通道，或兼容旧的 prepatch/preminor/premajor/prerelease

选项:
  --preid <id>   指定预发布标识，默认 beta
  -y, --yes      跳过最终确认
  --dry-run      只计算版本并打印，不执行写入和推送
  --skip-analyze 跳过 flutter analyze
  --skip-test    跳过发版前测试（默认只跑 test/architecture 架构守卫）
  --full-test    运行全量工作区测试（较慢）

不传版本参数时:
  进入交互式发版向导（可预览近期提交、切换通道、选择是否跳过检查或返回重选）
''';

enum _ConfirmAction { release, fastRelease, dryRun, reselect, cancel }

class _GitWorkingTreeStatus {
  const _GitWorkingTreeStatus({
    required this.trackedFiles,
    required this.untrackedFiles,
  });

  final List<String> trackedFiles;
  final List<String> untrackedFiles;

  bool get hasTrackedChanges => trackedFiles.isNotEmpty;
}

class _CommitSummary {
  const _CommitSummary({required this.totalCount, required this.samples});

  final int totalCount;
  final List<String> samples;
}

class _ReleaseOptions {
  const _ReleaseOptions({
    required this.target,
    required this.preid,
    required this.yes,
    required this.dryRun,
    required this.skipAnalyze,
    required this.skipTest,
    required this.fullTest,
    required this.track,
    required this.showHelp,
  });

  final String? target;
  final String? preid;
  final bool yes;
  final bool dryRun;
  final bool skipAnalyze;
  final bool skipTest;
  final bool fullTest;
  final _ReleaseTrack track;
  final bool showHelp;
}

class _VersionBaseline {
  const _VersionBaseline(
    this.version,
    this.source, {
    required this.latestTagName,
  });

  final _SemVersion version;
  final String source;
  final String? latestTagName;
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
  _cliUi.error('未知通道: $value，可选值为 release / prerelease / any');
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
      _cliUi.error('无法解析版本号: $input');
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
