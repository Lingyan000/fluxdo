import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/local_notification_service.dart' show navigatorKey;
import '../../utils/frame_jank_monitor.dart';

/// 全局悬浮性能监控面板。
///
/// 解决"监控只能在诊断页里开、看 —— 无法对具体场景做局部监控"的痛点:
/// 经全局 [navigatorKey] 的根 Overlay 插入,任何页面可见可拖;胶囊态
/// 常驻显示本段掉帧率,展开后可**启停监控**、清零(= 开始一段局部统计)、
/// 手动线程 CPU 采样、一键复制导出文本、隐藏面板。开关持久化,随
/// [FrameJankMonitor.start] 恢复。
class PerfOverlay {
  PerfOverlay._();

  static const prefKey = 'pref_perf_overlay';

  static OverlayEntry? _entry;

  /// 期望显示态:show/hide 的裁决源。navigator 未就绪时 show 会挂帧末
  /// 重试,期间用户关掉面板的话,凭它取消重试(否则关了又自己弹回)。
  static bool _wantShow = false;

  static bool get isShowing => _entry != null;

  /// 启动恢复:开关开着才插入;navigator 未就绪时逐帧重试(启动早期)。
  static Future<void> restoreIfEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(prefKey) ?? false) show();
    } catch (_) {}
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefKey, enabled);
    } catch (_) {}
    enabled ? show() : hide();
  }

  static void show() {
    _wantShow = true;
    if (_entry != null) return;
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) {
      // 启动早期 navigator 未挂载:下一帧再试(hide 会取消)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_wantShow && _entry == null) show();
      });
      return;
    }
    final entry = OverlayEntry(builder: (_) => const _PerfPanel());
    _entry = entry;
    overlay.insert(entry);
  }

  static void hide() {
    _wantShow = false;
    _entry?.remove();
    _entry = null;
  }
}

class _PerfPanel extends StatefulWidget {
  const _PerfPanel();

  @override
  State<_PerfPanel> createState() => _PerfPanelState();
}

class _PerfPanelState extends State<_PerfPanel> {
  final GlobalKey _panelKey = GlobalKey();
  Offset _pos = const Offset(8, 120);
  bool _expanded = false;
  bool _sampling = false;

  /// 展开前的胶囊位置:展开态可能因尺寸变大被钳制移位,收起时恢复原位;
  /// 展开期间用户手动拖过(置 null)则以拖后位置为准,不回弹。
  Offset? _posBeforeExpand;

  /// 钳制在窗口内:面板实际尺寸(拿不到时用胶囊保守值),任何时候
  /// 至少留全须可见 —— 拖出边界找不回是硬伤。
  Offset _clamp(Offset p) {
    final screen = MediaQuery.sizeOf(context);
    final size = _panelKey.currentContext?.size ?? const Size(72, 30);
    final maxX = (screen.width - size.width).clamp(0.0, double.infinity);
    final maxY = (screen.height - size.height).clamp(0.0, double.infinity);
    return Offset(p.dx.clamp(0.0, maxX), p.dy.clamp(0.0, maxY));
  }

  /// 展开/收起后尺寸变化,帧末按新尺寸补一次钳制。
  void _reclampAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final clamped = _clamp(_pos);
      if (clamped != _pos) setState(() => _pos = clamped);
    });
  }

  String get _rateText {
    final frames = FrameJankMonitor.sessionFrames;
    if (frames == 0) return '—';
    final rate = FrameJankMonitor.sessionJanks / frames * 100;
    return '${rate.toStringAsFixed(1)}%';
  }

  Color get _dotColor {
    if (!FrameJankMonitor.isRunning) return Colors.grey;
    final frames = FrameJankMonitor.sessionFrames;
    if (frames == 0) return Colors.grey;
    final rate = FrameJankMonitor.sessionJanks / frames * 100;
    if (rate < 1) return Colors.lightGreenAccent.shade700;
    if (rate < 3) return Colors.orange;
    return Colors.redAccent;
  }

  /// 诊断监控启停(与诊断页开关同源:prefs + start/stop),局部监控的
  /// 完整闭环不再依赖回诊断页。
  Future<void> _toggleMonitor() async {
    final running = FrameJankMonitor.isRunning;
    running ? FrameJankMonitor.stop() : FrameJankMonitor.start();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(FrameJankMonitor.prefKey, !running);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _sampleCpu() async {
    if (_sampling) return;
    setState(() => _sampling = true);
    await FrameJankMonitor.sampleThreadCpu();
    if (mounted) setState(() => _sampling = false);
  }

  Future<void> _copyExport() async {
    await Clipboard.setData(ClipboardData(text: FrameJankMonitor.exportText()));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _posBeforeExpand = null; // 手动挪过,收起后不回弹
          _pos = _clamp(_pos + d.delta);
        }),
        child: Material(
          key: _panelKey,
          color: Colors.black.withValues(alpha: 0.78),
          shape: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(10),
          ),
          elevation: 4,
          child: ValueListenableBuilder<int>(
            valueListenable: FrameJankMonitor.revision,
            builder: (context, _, _) =>
                _expanded ? _buildExpanded(context) : _buildCollapsed(context),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context) {
    return InkWell(
      onTap: () {
        _posBeforeExpand = _pos;
        setState(() => _expanded = true);
        _reclampAfterLayout();
      },
      customBorder: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: _dotColor),
            const SizedBox(width: 6),
            Text(
              FrameJankMonitor.isRunning ? _rateText : '暂停',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context) {
    final frames = FrameJankMonitor.sessionFrames;
    final janks = FrameJankMonitor.sessionJanks;
    final last = FrameJankMonitor.jankRecords.isEmpty
        ? null
        : FrameJankMonitor.jankRecords.last;
    String ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);
    const labelStyle = TextStyle(color: Colors.white70, fontSize: 11);
    const valueStyle = TextStyle(
      color: Colors.white,
      fontSize: 11,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 8, color: _dotColor),
              const SizedBox(width: 6),
              Text(
                FrameJankMonitor.isRunning
                    ? '$janks/$frames 掉帧 $_rateText'
                    : '监控已暂停',
                style: valueStyle,
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: () {
                  final restore = _posBeforeExpand;
                  _posBeforeExpand = null;
                  setState(() {
                    _expanded = false;
                    if (restore != null) _pos = restore;
                  });
                  _reclampAfterLayout();
                },
                child: const Icon(
                  Icons.unfold_less,
                  size: 14,
                  color: Colors.white54,
                ),
              ),
            ],
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '最近 #${last.frameNumber} ${ms(last.total)}ms '
                '(b${ms(last.buildDuration)}/r${ms(last.rasterDuration)})',
                style: labelStyle,
              ),
            ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _btn(FrameJankMonitor.isRunning ? '暂停' : '开始', _toggleMonitor),
              _btn('清零', FrameJankMonitor.clear),
              if (FrameJankMonitor.cpuSampleSupported)
                _btn(_sampling ? '采样中…' : 'CPU', _sampleCpu),
              _btn('复制', _copyExport),
              _btn('隐藏', () => PerfOverlay.setEnabled(false)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(6),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: ShapeDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(6),
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      ),
    );
  }
}
