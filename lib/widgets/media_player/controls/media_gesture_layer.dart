import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../../../utils/platform_utils.dart';

/// 播放器手势层(叠在控制条之下),按输入模态分两套语义:
///
/// **移动端(触摸)**:
/// - 单击:toggle 控制条
/// - 双击:播放/暂停(全区 —— 分区双击 seek 已删:有横滑调进度后
///   属于冗余入口,且侧区误触会让「双击暂停」变成 seek)
/// - 横滑:调进度(滑满一屏宽 = ±90s,松手提交;inline 与全屏都开;
///   左右 24px 边缘让给系统返回手势)
/// - 长按:2x 快进(松手恢复)+ 触觉反馈
/// - 竖滑(仅全屏):右半屏系统音量,左半屏 app 亮度
///
/// **桌面端(鼠标)**:
/// - 单击:播放/暂停(立即生效,无双击消歧延迟)
/// - 双击:切全屏(300ms 内第二击 → 撤销第一击的播/停再切,
///   主流桌面播放器同款,避免 onDoubleTap 给单击加延迟)
/// - 长按:2x 快进
/// - 控制条显隐完全交给鼠标悬停(控制层治理),点击不参与 ——
///   「点掉→鼠标一动又回来」的模态打架从根上消除。
class MediaGestureLayer extends StatefulWidget {
  const MediaGestureLayer({
    super.key,
    required this.onToggleControls,
    required this.onTogglePlay,
    required this.onLongPressSpeedChanged,
    this.onDesktopDoubleTapFullscreen,
    this.onVerticalAdjust,
    this.enableVerticalGestures = false,
    this.positionProvider,
    this.durationProvider,
    this.onSeekPreview,
    this.onSeekCommit,
    this.child,
  });

  /// 移动端单击:toggle 控制条(桌面端不走此回调)。
  final VoidCallback onToggleControls;
  final VoidCallback onTogglePlay;

  /// 长按 2x 状态变化(true=按下进入,false=松手退出)。
  final ValueChanged<bool> onLongPressSpeedChanged;

  /// 桌面端双击切全屏。
  final VoidCallback? onDesktopDoubleTapFullscreen;

  /// 竖滑手势 HUD 数据回调(isVolume, value, visible)。
  final void Function(bool isVolume, double value, bool visible)?
      onVerticalAdjust;

  /// 竖滑调音量/亮度,仅移动端全屏开。
  final bool enableVerticalGestures;

  /// 横滑 seek 的数据源(当前位置/总时长),null = 禁用横滑 seek。
  final Duration Function()? positionProvider;
  final Duration Function()? durationProvider;

  /// 横滑中的目标位置预览(null = 拖动结束,HUD 应隐藏)。
  /// [cancelArmed]:手指已拖入顶部取消区,松开将不提交。
  final void Function(Duration? target,
      {required bool forward, required bool cancelArmed})? onSeekPreview;

  /// 横滑松手提交。
  final ValueChanged<Duration>? onSeekCommit;

  final Widget? child;

  @override
  State<MediaGestureLayer> createState() => _MediaGestureLayerState();
}

class _MediaGestureLayerState extends State<MediaGestureLayer> {
  static final bool _isMobile = !PlatformUtils.isDesktop;

  /// 横滑映射:滑满一屏(播放器)宽 = 90 秒(绝对映射,
  /// 比按视频长度等比映射稳定 —— 长视频不会一碰就飞几分钟)。
  static const Duration _fullWidthSeek = Duration(seconds: 90);

  /// 左右边缘豁免区:iOS 系统返回手势从屏缘起手,inline 播放器通常
  /// 全宽贴屏,这里不抢。
  static const double _edgeExclusion = 24;

  bool _longPressActive = false;

  /// 桌面端双击判定窗口:第一击已立即执行播/停,窗口内第二击到来
  /// 则撤销(再 toggle 一次)并切全屏。
  Timer? _desktopTapWindow;

  // 横滑 seek 状态
  Duration? _seekBase;
  Duration? _seekTarget;
  double _seekAccumDx = 0;
  bool _seekForward = true;

  /// 手指当前是否在顶部取消区(屏高上部 1/8),松手即放弃本次 seek。
  bool _seekCancelArmed = false;

  // 竖滑状态
  bool? _verticalIsVolume;
  double _verticalStartValue = 0;
  double _verticalAccum = 0;
  Timer? _hudHideTimer;

  bool get _verticalEnabled =>
      widget.enableVerticalGestures && _isMobile;

  bool get _seekGestureEnabled =>
      _isMobile &&
      widget.positionProvider != null &&
      widget.onSeekCommit != null;

  @override
  void dispose() {
    _hudHideTimer?.cancel();
    _desktopTapWindow?.cancel();
    if (_longPressActive) widget.onLongPressSpeedChanged(false);
    super.dispose();
  }

  /// 桌面端单击:立即播/停(不等双击消歧);300ms 内第二击 = 双击 →
  /// 撤销第一击的播/停,切全屏。
  void _handleDesktopTap() {
    final pending = _desktopTapWindow;
    if (pending != null && pending.isActive) {
      pending.cancel();
      _desktopTapWindow = null;
      widget.onTogglePlay(); // 撤销第一击
      widget.onDesktopDoubleTapFullscreen?.call();
      return;
    }
    widget.onTogglePlay();
    _desktopTapWindow = Timer(const Duration(milliseconds: 300), () {});
  }

  // ---- 横滑 seek ----

  void _startSeekDrag(DragStartDetails details) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final x = details.localPosition.dx;
    if (x < _edgeExclusion || x > width - _edgeExclusion) return;
    final duration = widget.durationProvider?.call() ?? Duration.zero;
    if (duration == Duration.zero) return; // 未初始化不响应
    _seekBase = widget.positionProvider?.call();
    _seekTarget = _seekBase;
    _seekAccumDx = 0;
    _seekCancelArmed = false;
  }

  void _updateSeekDrag(DragUpdateDetails details) {
    final base = _seekBase;
    if (base == null) return;
    final size = context.size;
    if (size == null || size.width <= 0) return;
    _seekAccumDx += details.delta.dx;
    final duration = widget.durationProvider!.call();
    var target = base + _fullWidthSeek * (_seekAccumDx / size.width);
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    _seekForward = target >= base;
    _seekTarget = target;
    // 取消区:拖入播放器上部 1/8 视为要放弃(主流播放器同型交互);
    // 进出取消区给触觉反馈
    final cancelArmed = details.localPosition.dy < size.height / 8;
    if (cancelArmed != _seekCancelArmed) {
      _seekCancelArmed = cancelArmed;
      HapticFeedback.selectionClick();
    }
    widget.onSeekPreview
        ?.call(target, forward: _seekForward, cancelArmed: cancelArmed);
  }

  void _endSeekDrag({required bool commit}) {
    if (_seekBase == null) return;
    final target = _seekTarget;
    final cancelled = _seekCancelArmed;
    _seekBase = null;
    _seekTarget = null;
    _seekCancelArmed = false;
    widget.onSeekPreview
        ?.call(null, forward: _seekForward, cancelArmed: false);
    if (commit && !cancelled && target != null) {
      widget.onSeekCommit?.call(target);
    }
  }

  // ---- 竖滑音量/亮度 ----

  Future<void> _startVertical(DragStartDetails details) async {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final isVolume = details.localPosition.dx >= width / 2;
    _verticalAccum = 0;
    try {
      _verticalStartValue = isVolume
          ? await VolumeController.instance.getVolume()
          : await ScreenBrightness().application;
    } catch (_) {
      return; // 平台不支持(如模拟器)则本次手势静默失效
    }
    if (!mounted) return;
    _verticalIsVolume = isVolume;
    _hudHideTimer?.cancel();
    widget.onVerticalAdjust?.call(isVolume, _verticalStartValue, true);
  }

  void _updateVertical(DragUpdateDetails details) {
    final isVolume = _verticalIsVolume;
    if (isVolume == null) return;
    final height = context.size?.height ?? 0;
    if (height <= 0) return;
    // 上滑增大;整屏高度对应满量程
    _verticalAccum -= details.delta.dy / height;
    final value = (_verticalStartValue + _verticalAccum).clamp(0.0, 1.0);
    widget.onVerticalAdjust?.call(isVolume, value, true);
    if (isVolume) {
      VolumeController.instance.showSystemUI = false;
      unawaited(VolumeController.instance.setVolume(value));
    } else {
      unawaited(
          ScreenBrightness().setApplicationScreenBrightness(value));
    }
  }

  void _endVertical() {
    final isVolume = _verticalIsVolume;
    if (isVolume == null) return;
    _verticalIsVolume = null;
    final value = (_verticalStartValue + _verticalAccum).clamp(0.0, 1.0);
    // HUD 略作停留再隐藏
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(milliseconds: 600), () {
      widget.onVerticalAdjust?.call(isVolume, value, false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isMobile) {
      // 桌面:单击播/停 + 手动双击判定切全屏 + 长按 2x。
      // 不挂 onDoubleTap(它会给单击加 300ms 消歧延迟,暂停不跟手);
      // 控制条显隐由控制层的 MouseRegion 悬停治理,点击不参与。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleDesktopTap,
        onLongPressStart: (_) {
          _longPressActive = true;
          widget.onLongPressSpeedChanged(true);
        },
        onLongPressEnd: (_) {
          _longPressActive = false;
          widget.onLongPressSpeedChanged(false);
        },
        onLongPressCancel: () {
          if (!_longPressActive) return;
          _longPressActive = false;
          widget.onLongPressSpeedChanged(false);
        },
        child: widget.child,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleControls,
      onDoubleTap: widget.onTogglePlay,
      onLongPressStart: (_) {
        _longPressActive = true;
        HapticFeedback.lightImpact();
        widget.onLongPressSpeedChanged(true);
      },
      onLongPressEnd: (_) {
        _longPressActive = false;
        widget.onLongPressSpeedChanged(false);
      },
      onLongPressCancel: () {
        if (!_longPressActive) return;
        _longPressActive = false;
        widget.onLongPressSpeedChanged(false);
      },
      onHorizontalDragStart:
          _seekGestureEnabled ? _startSeekDrag : null,
      onHorizontalDragUpdate:
          _seekGestureEnabled ? _updateSeekDrag : null,
      onHorizontalDragEnd:
          _seekGestureEnabled ? (_) => _endSeekDrag(commit: true) : null,
      onHorizontalDragCancel:
          _seekGestureEnabled ? () => _endSeekDrag(commit: false) : null,
      onVerticalDragStart:
          _verticalEnabled ? (d) => unawaited(_startVertical(d)) : null,
      onVerticalDragUpdate: _verticalEnabled ? _updateVertical : null,
      onVerticalDragEnd: _verticalEnabled ? (_) => _endVertical() : null,
      onVerticalDragCancel: _verticalEnabled ? _endVertical : null,
      child: widget.child,
    );
  }
}
