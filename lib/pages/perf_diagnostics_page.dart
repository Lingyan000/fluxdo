import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/toast_service.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/glyph_warmer.dart';
import '../utils/jank_profiler.dart';
import '../widgets/common/perf_overlay.dart';

/// 性能诊断页:查看/导出 [FrameJankMonitor] 采集的掉帧记录与场景事件,
/// 不依赖 adb/logcat。开发者向工具页,文案暂不接入 l10n。
class PerfDiagnosticsPage extends StatefulWidget {
  const PerfDiagnosticsPage({super.key});

  @override
  State<PerfDiagnosticsPage> createState() => _PerfDiagnosticsPageState();
}

class _PerfDiagnosticsPageState extends State<PerfDiagnosticsPage> {
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

  Future<void> _share() async {
    await SharePlus.instance.share(
      ShareParams(
        text: FrameJankMonitor.exportText(),
        subject: 'FluxDO 性能诊断报告',
      ),
    );
  }

  void _clear() {
    FrameJankMonitor.clear();
    ToastService.showInfo('已清空记录');
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
            tooltip: '分享报告',
            icon: const Icon(Symbols.share_rounded),
            onPressed: _share,
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('字形图集预热'),
              subtitle: const Text(
                '空闲帧把帖子中文字形提前画进 GPU 图集,'
                '消除滚动中的图集扩容大帧(时间轴 warm 标记;重启后保持)',
              ),
              value: GlyphWarmer.enabled,
              onChanged: (v) async {
                GlyphWarmer.enabled = v;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(GlyphWarmer.prefKey, v);
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
