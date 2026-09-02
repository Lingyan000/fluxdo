import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:cross_file/cross_file.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/toast_service.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/jank_profiler.dart';
import '../utils/share_utils.dart';
import '../widgets/common/perf_overlay.dart';

/// 性能诊断页:查看/导出 [FrameJankMonitor] 采集的掉帧记录与场景事件,
/// 不依赖 adb/logcat。开发者向工具页,文案暂不接入 l10n。
class PerfDiagnosticsPage extends StatefulWidget {
  const PerfDiagnosticsPage({super.key});

  @override
  State<PerfDiagnosticsPage> createState() => _PerfDiagnosticsPageState();
}

class _PerfDiagnosticsPageState extends State<PerfDiagnosticsPage> {
  /// 上次会话快照(退后台时落盘的 perf_diag_last.txt),null = 不存在
  File? _snapshotFile;

  @override
  void initState() {
    super.initState();
    FrameJankMonitor.snapshotFile().then((f) {
      if (mounted) setState(() => _snapshotFile = f);
    });
  }

  Future<void> _toggle(bool enabled) async {
    if (enabled) {
      FrameJankMonitor.start();
    } else {
      FrameJankMonitor.stop();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(FrameJankMonitor.prefKey, enabled);
    if (mounted) setState(() {});
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: FrameJankMonitor.exportText()),
    );
    ToastService.showSuccess('诊断报告已复制');
  }

  /// 导出报告为文件。
  ///
  /// 原先是把整份报告塞进 ShareParams.text —— Linux 与 RS5 以下 Windows 的
  /// share_plus 把 text 拼进 `mailto:` query,一份完整报告必然超长失败,而且
  /// 这里没有 try/catch,异常会变成未捕获的异步错误。
  Future<void> _export({required bool share}) async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = await ShareUtils.createOutboxFile('fluxdo_perf_$stamp.txt');
      await file.writeAsString(FrameJankMonitor.exportText());
      await _deliver(XFile(file.path, mimeType: 'text/plain'), share: share);
    } catch (e) {
      if (mounted) ToastService.showError('导出失败: $e');
    }
  }

  /// 分享或保存同一份文件（分享在 Linux 上不可用，入口已按平台隐藏）。
  Future<void> _deliver(XFile file, {required bool share}) async {
    if (share) {
      await ShareUtils.shareFile(file, subject: 'FluxDO 性能诊断报告');
      return;
    }
    final outcome = await ShareUtils.saveFile(file);
    if (outcome.shared && mounted) {
      ToastService.showSuccess('已保存: ${outcome.displayName ?? ''}');
    }
  }

  void _clear() {
    FrameJankMonitor.clear();
    ToastService.showInfo('已清空记录');
  }

  Future<void> _deliverSnapshot({required bool share}) async {
    final file = _snapshotFile;
    if (file == null) return;
    try {
      // 快照本来就是磁盘上的文件,直接交出去,不必读成文本
      await _deliver(XFile(file.path, mimeType: 'text/plain'), share: share);
    } catch (e) {
      if (mounted) ToastService.showError('导出快照失败: $e');
    }
  }

  String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('性能诊断'),
        actions: [
          IconButton(
            tooltip: '复制报告',
            icon: const Icon(Symbols.content_copy_rounded),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: '保存报告',
            icon: const Icon(Symbols.save_alt_rounded),
            onPressed: () => _export(share: false),
          ),
          if (ShareUtils.canShareFiles)
            IconButton(
              tooltip: '分享报告',
              icon: const Icon(Symbols.share_rounded),
              onPressed: () => _export(share: true),
            ),
          IconButton(
            tooltip: '清空记录',
            icon: const Icon(Symbols.delete_sweep_rounded),
            onPressed: _clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: FrameJankMonitor.revision,
        builder: (context, _, _) {
          final janks = FrameJankMonitor.jankRecords;
          final events = FrameJankMonitor.events;
          // 合并时间轴,最新在前
          final entries = <(_EntryKind, DateTime, Widget)>[
            for (final j in janks)
              (_EntryKind.jank, j.time, _jankTile(theme, j)),
            for (final e in events)
              (_EntryKind.event, e.time, _eventTile(theme, e)),
          ]..sort((a, b) => b.$2.compareTo(a.$2));

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _summaryCard(theme),
              const SizedBox(height: 12),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: Center(
                    child: Text(
                      FrameJankMonitor.isRunning
                          ? '暂无掉帧记录,去滚动几屏试试'
                          : '监控未启用',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                ...entries.map((e) => e.$3),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCard(ThemeData theme) {
    final frames = FrameJankMonitor.sessionFrames;
    final janks = FrameJankMonitor.sessionJanks;
    final rate = frames == 0 ? 0.0 : janks / frames * 100;
    final refresh = FrameJankMonitor.displayRefreshRate();
    final semanticsNodes = FrameJankMonitor.countSemanticsNodes();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用监控'),
              subtitle: Text(
                kReleaseMode
                    ? '记录掉帧与场景事件(重启后保持)'
                    : 'debug/profile 构建自动启用',
              ),
              value: FrameJankMonitor.isRunning,
              onChanged: _toggle,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('悬浮监控面板'),
              subtitle: const Text(
                '全局悬浮显示掉帧率,可随时清零做局部统计、'
                '手动线程 CPU 采样、复制导出(重启后保持)',
              ),
              value: PerfOverlay.isShowing,
              onChanged: (v) async {
                await PerfOverlay.setEnabled(v);
                if (mounted) setState(() {});
              },
            ),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Text(
              '本次会话:$frames 帧,掉帧 $janks 次'
              '(${rate.toStringAsFixed(1)}%)',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'worst build ${_ms(FrameJankMonitor.sessionWorstBuild)}ms / '
              'worst raster ${_ms(FrameJankMonitor.sessionWorstRaster)}ms',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '刷新率 ${refresh?.toStringAsFixed(0) ?? '?'}Hz · '
              '语义树 ${semanticsNodes < 0 ? '未启用' : '$semanticsNodes 节点'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '现场抓取 ${JankProfiler.status}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_snapshotFile != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '上次会话快照 '
                      '(${_fmtSnapshotTime(_snapshotFile!.lastModifiedSync())})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '保存上次会话快照',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Symbols.save_alt_rounded, size: 18),
                    onPressed: () => _deliverSnapshot(share: false),
                  ),
                  if (ShareUtils.canShareFiles)
                    IconButton(
                      tooltip: '分享上次会话快照',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Symbols.share_rounded, size: 18),
                      onPressed: () => _deliverSnapshot(share: true),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  String _fmtSnapshotTime(DateTime t) =>
      '${t.month}/${t.day} ${_fmtTime(t)}';

  Widget _jankTile(ThemeData theme, JankRecord j) {
    final heavy = j.total.inMilliseconds >= 20;
    final color = heavy ? theme.colorScheme.error : theme.colorScheme.tertiary;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(Symbols.warning_rounded, size: 18, color: color),
      title: Text(
        '${_ms(j.total)}ms · build ${_ms(j.buildDuration)} / '
        'raster ${_ms(j.rasterDuration)} / ov ${_ms(j.vsyncOverhead)}',
        style: theme.textTheme.bodySmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      subtitle: (j.cause == null && j.detail == null)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (j.cause != null)
                  Text(
                    j.cause!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontSize: 11,
                    ),
                  ),
                if (j.detail != null)
                  Text(
                    j.detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
      trailing: Text(
        _fmtTime(j.time),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _eventTile(ThemeData theme, DiagEvent e) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        Symbols.info_rounded,
        size: 18,
        color: theme.colorScheme.outline,
      ),
      title: Text(
        '[${e.tag}] ${e.message}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        _fmtTime(e.time),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }
}

enum _EntryKind { jank, event }
