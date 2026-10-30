import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:m3e_ui/m3e_ui.dart';

import 'local_notification_service.dart';

/// Toast 类型
enum ToastType { success, error, info }

/// 徽章与配色语义；download 只由下载句柄使用，完成时原位切到 success
enum _ToastKind { success, error, info, download }

@immutable
class _ToastData {
  const _ToastData({
    required this.kind,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final _ToastKind kind;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  _ToastData withMessage(String message) => _ToastData(
    kind: kind,
    message: message,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// [ToastType] 与内部语义的映射
_ToastKind _kindOf(ToastType type) => switch (type) {
  ToastType.success => _ToastKind.success,
  ToastType.error => _ToastKind.error,
  ToastType.info => _ToastKind.info,
};

/// 挂在 Overlay 上的一次 Toast。下载完成时只替换 [data]，外壳、位置和
/// 入场状态都不动，才能表现为"原位变身"而不是先收起再弹出一个新的。
class _ToastSession {
  _ToastSession(_ToastData data, {this.isProgress = false})
    : data = ValueNotifier(data);

  final ValueNotifier<_ToastData> data;
  final progress = ValueNotifier<double>(-1.0); // -1 = 不确定进度

  /// 轻脉冲计数：同一件事重复触发时，给徽章一次"又生效了"的反馈
  final pulseTick = ValueNotifier<int>(0);

  /// 来自下载/同步这类带进度的提示：长期占住主槽位，普通提示不顶掉它，
  /// 而是下移让位（见 ToastService._stacked）
  final bool isProgress;

  OverlayEntry? _entry;
  AnimationController? _controller;
  Timer? _timer;
  bool _closed = false; // 逻辑关闭：不再接受进度与文案更新
  bool _released = false; // 资源已释放：收尾可能被打断，必须幂等

  bool get isClosed => _closed;

  void scheduleDismiss(Duration duration) {
    _timer?.cancel();
    _timer = Timer(duration, () => close(animate: true));
  }

  /// 同一件事又发生了一次：不重播入场，只让徽章弹一下
  void pulse() {
    if (!_closed) pulseTick.value++;
  }

  void close({required bool animate}) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    final controller = _controller;
    final entry = _entry;

    // 退场直接倒放入场：文字先淡出，胶囊收回圆点，最后消失。
    // 倒放期间 entry 还留在 Overlay 上，此刻若插入新 Toast，两条会同时可见，
    // 所以要登记成 outgoing，由下一次 _present 提前收尾。
    if (animate && controller != null && entry != null) {
      ToastService._outgoing.add(this);
      controller.reverse().whenCompleteOrCancel(_release);
    } else {
      // 这里不能先清 _entry：_release 还要靠它把 entry 从 Overlay 摘掉
      _release();
    }
  }

  /// 幂等收尾：倒放正常结束、或被新 Toast 提前打断，都走这里。
  void _release() {
    if (_released) return;
    _released = true;
    ToastService._outgoing.remove(this);
    // 仍在倒放时 Ticker 是 active，直接卸树会在 dispose 中断言失败
    _controller?.stop();
    _controller = null;
    _entry?.remove();
    _entry = null;
    // 释放放在移除 entry 之后：State 卸载要等下一帧，期间 build 仍会读值
    data.dispose();
    progress.dispose();
    pulseTick.dispose();
    ToastService._onSessionReleased(this);
  }

  /// 视图被卸载：entry 与 controller 已随视图一起消失，此时再 stop/remove
  /// 只会打到已 dispose 的对象。整棵树被替换（登出、换 navigator）时，
  /// 收尾回调会晚于卸载到达，必须靠这里先标记掉。
  void _onViewDisposed() {
    _closed = true;
    _released = true;
    _timer?.cancel();
    _timer = null;
    _controller = null;
    _entry = null;
    ToastService._outgoing.remove(this);
    ToastService._onSessionReleased(this);
  }
}

/// 下载进度 Toast 句柄
class DownloadToastHandle {
  DownloadToastHandle._(this._session);

  final _ToastSession? _session;
  bool _finished = false;

  bool get isActive =>
      !_finished && _session != null && !_session.isClosed;

  /// 更新下载进度（0.0~1.0，-1 为不确定进度）
  void updateProgress(double value) {
    if (isActive) _session!.progress.value = value;
  }

  /// 更新显示的文件名（HEAD 请求获取到更好的文件名时调用）
  void updateFileName(String name) {
    if (!isActive) return;
    final data = _session!.data;
    data.value = data.value.withMessage(name);
  }

  /// 在原位置变成结果提示：默认成功，失败传 [ToastType.error] 原位变色。
  /// 之后按普通 Toast 计时消失；若 Toast 已被划走或关闭，退化为新弹一条。
  /// [duration] 不传时用错误 5s、其余 3s 的默认值。
  void complete(
    String message, {
    ToastType type = ToastType.success,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final effective = duration ?? ToastService._defaultDuration(type);
    if (!isActive) {
      _detach();
      ToastService.show(
        message,
        type: type,
        duration: effective,
        actionLabel: actionLabel,
        onAction: onAction,
      );
      return;
    }
    final session = _session!;
    _detach();
    session.data.value = _ToastData(
      kind: _kindOf(type),
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    session.scheduleDismiss(effective);
  }

  /// 关闭 Toast
  void dismiss() {
    if (_finished) return;
    _detach();
    _session?.close(animate: true);
  }

  void _detach() {
    _finished = true;
    if (identical(ToastService._downloadHandle, this)) {
      ToastService._downloadHandle = null;
    }
  }
}

/// 全局 Toast 服务（基于 Overlay，显示在屏幕顶部）
///
/// 两个槽位：主槽位放下载/同步这类带进度的提示，或一条普通提示。进度提示
/// 占着主槽位时，普通提示落到次槽位（顶部下方一点），互不打断；进度提示
/// 收尾后，次槽位的那条会升上来接替主槽位。
class ToastService {
  static _ToastSession? _current; // 主槽位
  static _ToastSession? _stacked; // 次槽位：让位中的普通提示
  /// 正在播退场动画的 Toast：新的出现前必须先把它收掉，否则同屏两条
  static final List<_ToastSession> _outgoing = [];
  static DownloadToastHandle? _downloadHandle;

  /// 主槽位是否被带进度的提示占着：普通提示据此下移让位
  static final ValueNotifier<bool> _progressOnTop = ValueNotifier<bool>(false);

  /// 错误提示默认停留更久，够看清出了什么问题
  static Duration _defaultDuration(ToastType type) => type == ToastType.error
      ? const Duration(seconds: 5)
      : const Duration(seconds: 3);

  /// 显示 Toast
  static void show(
    String message, {
    ToastType type = ToastType.info,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final data = _ToastData(
      kind: _kindOf(type),
      message: message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    final effective = duration ?? _defaultDuration(type);

    // 同一件事重复触发（连点复制、连续点赞）：不重播入场，只重置计时并让
    // 徽章弹一下——否则每次都从头展开，观感很抖
    final repeat = _findRepeat(data);
    if (repeat != null) {
      repeat.scheduleDismiss(effective);
      repeat.pulse();
      return;
    }

    final session = _present(data);
    session?.scheduleDismiss(effective);
  }

  /// 显示下载进度 Toast（持久，不自动消失）
  static DownloadToastHandle showDownload(String fileName) {
    // 旧的下载 Toast 由下面的替换直接移除，这里只让旧句柄失效
    _downloadHandle?._detach();

    // 主槽位上的普通提示不丢：挪到次槽位，随进度胶囊出现一起下移让位
    final notice = _current;
    if (notice != null && !notice.isProgress && !notice.isClosed) {
      _stacked?._release();
      _stacked = notice;
      _current = null;
    }

    final handle = DownloadToastHandle._(
      _present(_ToastData(kind: _ToastKind.download, message: fileName)),
    );
    if (handle._session == null) {
      // 没有 Overlay 可用：把刚挪走的提示放回主槽位
      _current ??= _stacked;
      _stacked = null;
      _refreshProgressOnTop();
    } else {
      _downloadHandle = handle;
    }
    return handle;
  }

  /// 显示成功提示
  static void showSuccess(String message) {
    show(message, type: ToastType.success);
  }

  /// 显示错误提示
  static void showError(String message) {
    show(message, type: ToastType.error);
  }

  /// 显示信息提示
  static void showInfo(String message) {
    show(message, type: ToastType.info);
  }

  /// 找到可以合并的同类提示（同类型、同文案、同操作）
  static _ToastSession? _findRepeat(_ToastData data) {
    for (final session in [_current, _stacked]) {
      if (session == null || session.isClosed || session.isProgress) continue;
      final current = session.data.value;
      if (current.kind == data.kind &&
          current.message == data.message &&
          current.actionLabel == data.actionLabel) {
        return session;
      }
    }
    return null;
  }

  /// 挂上一条新的 Toast：进度提示占主槽位；主槽位被进度提示占着时，普通
  /// 提示落次槽位下移让位，而不是把它顶掉。
  static _ToastSession? _present(_ToastData data) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return null;

    final toStack =
        data.kind != _ToastKind.download && _current?.isProgress == true;
    final replaced = toStack ? _stacked : _current;
    if (toStack) {
      _stacked = null;
    } else {
      // 先摘掉主槽位的记录：否则 _onSessionReleased 会误把次槽位里的提示
      // 提升上来，挤掉马上要插入的这条
      _current = null;
      for (final session in List.of(_outgoing)) {
        session._release();
      }
    }
    replaced?.close(animate: false);

    final session = _ToastSession(
      data,
      isProgress: data.kind == _ToastKind.download,
    );
    final entry = OverlayEntry(builder: (_) => _ToastView(session: session));
    session._entry = entry;
    if (toStack) {
      _stacked = session;
    } else {
      _current = session;
    }
    _refreshProgressOnTop();
    overlay.insert(entry);
    return session;
  }

  /// 一条 Toast 彻底收尾：腾出槽位，必要时把下方那条提升上来
  static void _onSessionReleased(_ToastSession session) {
    if (identical(_current, session)) {
      _current = null;
      final promoted = _stacked;
      if (promoted != null && !promoted.isClosed) {
        _stacked = null;
        _current = promoted;
      }
    } else if (identical(_stacked, session)) {
      _stacked = null;
    }
    _refreshProgressOnTop();
  }

  /// 主槽位只要还是进度来源的提示就算"占着顶部"——包括正在退场、entry 还
  /// 没摘掉的那条：它仍在屏幕上，普通提示就得待在它下面。
  static void _refreshProgressOnTop() {
    final top = _current;
    final value = top != null && top.isProgress;
    if (_progressOnTop.value != value) _progressOnTop.value = value;
  }
}

/// 形态与动效沿用"灵动胶囊"：圆点展开成胶囊、花瓣徽章回弹、下载完成
/// 原位变身；材质走全局玻璃，开关、档位与高对比度由 GlassSurface 统一
/// 降级为实色，这里不再各自判断。
class _ToastView extends StatefulWidget {
  const _ToastView({required this.session});

  final _ToastSession session;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with TickerProviderStateMixin {
  static const _radius = 28.0;
  static const _enterDuration = Duration(milliseconds: 560);
  static const _exitDuration = Duration(milliseconds: 300);
  static const _settleDuration = Duration(milliseconds: 420);

  // 以下时间片都落在入场控制器 [0, 1] 上；弹簧曲线的周期按片长换算，
  // 保证弹簧在片内收敛。
  static const _fadeCurve = Interval(0, 0.3, curve: Curves.easeOut);
  static final Curve _liftSpring = M3eMotion.defaultSpatial.curveFor(
    _enterDuration,
  );
  static final Curve _revealSpring = Interval(
    0.06,
    1,
    curve: M3eMotion.defaultSpatial.curveFor(_enterDuration * 0.94),
  );
  static final Curve _petalSpring = Interval(
    0,
    0.9,
    curve: M3eMotion.fastSpatial.curveFor(_enterDuration * 0.9),
  );
  static const _contentCurve = Interval(0.3, 0.7, curve: Curves.easeOutCubic);
  static const _checkCurve = Interval(0.42, 0.82, curve: Curves.easeOutCubic);
  static final Curve _resizeSpring = M3eMotion.defaultSpatial.curveFor(
    const Duration(milliseconds: 480),
  );

  // 完成态切换：徽章先缩后弹，同时换色、重描对勾
  static const _settleColorCurve = Interval(0, 0.5, curve: Curves.easeOut);
  static const _settleCheckCurve = Interval(
    0.15,
    0.7,
    curve: Curves.easeOutCubic,
  );
  static final _settleScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.86, end: 1.1).chain(CurveTween(curve: Curves.easeOut)),
      weight: 60,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.1, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 40,
    ),
  ]);
  static final _settleTilt = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: -0.14, end: 0.07).chain(CurveTween(curve: Curves.easeOut)),
      weight: 60,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.07, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 40,
    ),
  ]);

  // 同一件事重复触发：徽章弹一下，不做整条胶囊的形变
  static final _pulseScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.12).chain(CurveTween(curve: Curves.easeOut)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.12, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 55,
    ),
  ]);

  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: _enterDuration,
    reverseDuration: _exitDuration,
  );
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: _settleDuration,
    value: 1,
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final Listenable _repaint = Listenable.merge([
    _enter,
    _settle,
    _pulse,
    widget.session.data,
    widget.session.progress,
  ]);
  late _ToastKind _kind = widget.session.data.value.kind;
  late _ToastKind _fromKind = _kind;
  double _dragOffset = 0;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    widget.session._controller = _enter;
    widget.session.data.addListener(_onDataChanged);
    widget.session.pulseTick.addListener(_onPulse);
    _enter.forward();
  }

  @override
  void dispose() {
    // 先让 session 忘掉 entry/controller：卸载会取消 Ticker，收尾回调可能
    // 晚一步到达，那时这两个对象已经不存在了
    widget.session._onViewDisposed();
    widget.session.data.removeListener(_onDataChanged);
    widget.session.pulseTick.removeListener(_onPulse);
    _enter.dispose();
    _settle.dispose();
    _pulse.dispose();
    super.dispose();
  }

  /// 同一件事又发生一次：徽章弹一下，告诉用户"这次也生效了"
  void _onPulse() {
    if (!mounted) return;
    final expressive =
        !MediaQuery.disableAnimationsOf(context) &&
        M3eFlags.of(context).enabled;
    if (expressive) _pulse.forward(from: 0);
  }

  void _onDataChanged() {
    final kind = widget.session.data.value.kind;
    if (kind == _kind) return;
    _fromKind = _kind;
    _kind = kind;
    _settle.forward(from: 0);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_dismissing) return;
    // 只允许向上拖动
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dy).clamp(-double.infinity, 0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_dismissing) return;
    // 向上拖动超过 40px 或速度足够快则消失
    if (_dragOffset < -40 || details.velocity.pixelsPerSecond.dy < -200) {
      _dismissing = true;
      widget.session.close(animate: true);
    } else {
      // 弹回原位
      setState(() => _dragOffset = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Positioned(
      top: mediaQuery.padding.top + 12,
      left: 16,
      right: 16,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _StackSlot(
              // 进度提示自己就是让位的锚点，不需要下移
              active: !widget.session.isProgress,
              child: GestureDetector(
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                child: ListenableBuilder(
                  listenable: _repaint,
                  builder: (context, _) => _buildToast(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToast(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // 减弱动效：只保留淡入淡出；M3E 关闭：保留位移，去掉形变与回弹
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final expressive = !reduceMotion && M3eFlags.of(context).enabled;
    final data = widget.session.data.value;
    final t = _enter.value;

    final lift = reduceMotion
        ? 1.0
        : (expressive ? _liftSpring : Curves.easeOutCubic).transform(t);
    final reveal = expressive ? _revealSpring.transform(t) : 1.0;
    final content = expressive ? _contentCurve.transform(t) : 1.0;
    final dragFade = (1.0 + _dragOffset / 120).clamp(0.0, 1.0);

    return Opacity(
      opacity: _fadeCurve.transform(t) * dragFade,
      child: Transform.translate(
        offset: Offset(0, lerpDouble(-14, 0, lift)! + _dragOffset),
        child: Transform.scale(
          scale: lerpDouble(0.9, 1, lift),
          alignment: Alignment.topCenter,
          child: Semantics(
            container: true,
            liveRegion: true,
            child: DecoratedBox(
              // 浮在正文之上需要比导航更明显的落影
              decoration: ShapeDecoration(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_radius),
                ),
                shadows: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.10),
                    blurRadius: 24,
                    spreadRadius: -6,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: GlassSurfaceFrame(
                radius: _radius,
                recipe: GlassRecipe.menu,
                child: Material(
                  type: MaterialType.transparency,
                  child: _WidthReveal(
                    factor: reveal,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 480),
                      curve: expressive ? _resizeSpring : Curves.easeOutCubic,
                      alignment: Alignment.centerLeft,
                      child: _buildContent(
                        context,
                        data,
                        colorScheme,
                        expressive: expressive,
                        content: content,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    _ToastData data,
    ColorScheme colorScheme, {
    required bool expressive,
    required double content,
  }) {
    final theme = Theme.of(context);
    final t = _enter.value;
    final settling = _settle.isAnimating;
    final s = _settle.value;

    final (fromBg, fromFg) = _palette(colorScheme, _fromKind);
    final (toBg, toFg) = _palette(colorScheme, data.kind);
    final colorT = settling ? _settleColorCurve.transform(s) : 1.0;
    final badgeBg = Color.lerp(fromBg, toBg, colorT)!;
    final badgeFg = Color.lerp(fromFg, toFg, colorT)!;

    final petalIn = expressive ? _petalSpring.transform(t) : 1.0;
    final popScale = expressive && settling ? _settleScale.transform(s) : 1.0;
    final popTilt = expressive && settling ? _settleTilt.transform(s) : 0.0;
    final pulseScale = expressive && _pulse.isAnimating
        ? _pulseScale.transform(_pulse.value)
        : 1.0;
    // 下载态花瓣错开半瓣，完成时转回正位
    final baseTilt = lerpDouble(
      _baseTilt(_fromKind),
      _baseTilt(data.kind),
      colorT,
    )!;
    final check = math.min(
      expressive ? _checkCurve.transform(t) : 1.0,
      settling ? _settleCheckCurve.transform(s) : 1.0,
    );

    final progress = widget.session.progress.value;
    final isDownload = data.kind == _ToastKind.download;
    final hasAction = data.actionLabel != null;

    Widget slideIn(Widget child) => Opacity(
      opacity: content,
      child: Transform.translate(
        offset: Offset(lerpDouble(-6, 0, content)!, 0),
        child: child,
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(8, 8, hasAction ? 8 : 20, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToastBadge(
            kind: data.kind,
            background: badgeBg,
            foreground: badgeFg,
            petal: M3eFlags.of(context).enabled,
            scale: lerpDouble(0.72, 1, petalIn)! * popScale * pulseScale,
            tilt: lerpDouble(-0.72, 0, petalIn)! + popTilt + baseTilt,
            check: check,
            progress: progress,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: slideIn(
              Text(
                data.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
                maxLines: isDownload ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (isDownload && progress >= 0) ...[
            const SizedBox(width: 10),
            slideIn(
              Text(
                '${(progress * 100).toInt()}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
          if (hasAction) ...[
            const SizedBox(width: 12),
            slideIn(
              TextButton(
                onPressed: () {
                  data.onAction?.call();
                  widget.session.close(animate: true);
                },
                style: TextButton.styleFrom(
                  backgroundColor: toBg,
                  foregroundColor: toFg,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: const StadiumBorder(),
                  textStyle: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(data.actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static (Color, Color) _palette(ColorScheme colorScheme, _ToastKind kind) =>
      switch (kind) {
        _ToastKind.success => (
          colorScheme.primaryContainer,
          colorScheme.onPrimaryContainer,
        ),
        _ToastKind.error => (
          colorScheme.errorContainer,
          colorScheme.onErrorContainer,
        ),
        _ToastKind.info => (
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
        ),
        _ToastKind.download => (
          colorScheme.tertiaryContainer,
          colorScheme.onTertiaryContainer,
        ),
      };

  static double _baseTilt(_ToastKind kind) =>
      kind == _ToastKind.download ? math.pi / 8 : 0;
}

/// 状态徽章：花瓣底（M3E 关闭时为圆）+ 状态字形
class _ToastBadge extends StatelessWidget {
  const _ToastBadge({
    required this.kind,
    required this.background,
    required this.foreground,
    required this.petal,
    required this.scale,
    required this.tilt,
    required this.check,
    required this.progress,
  });

  static const double size = 40;

  final _ToastKind kind;
  final Color background;
  final Color foreground;
  final bool petal;
  final double scale;
  final double tilt;
  final double check;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final glyph = switch (kind) {
      _ToastKind.success => SizedBox.square(
        dimension: 22,
        child: CustomPaint(
          painter: _CheckmarkPainter(progress: check, color: foreground),
        ),
      ),
      _ToastKind.error => Icon(
        Symbols.priority_high_rounded,
        size: 22,
        color: foreground,
      ),
      _ToastKind.info => Icon(
        Symbols.info_i_rounded,
        size: 22,
        color: foreground,
      ),
      // 无进度=不定态波浪弧追逐,有进度=波浪环;同一组件连续过渡,无形态跳变
      _ToastKind.download => Stack(
        alignment: Alignment.center,
        children: [
          M3eCircularProgress(
            value: progress >= 0 ? progress : null,
            size: 30,
            strokeWidth: 2.5,
            color: foreground,
          ),
          Icon(Symbols.arrow_downward_rounded, size: 16, color: foreground),
        ],
      ),
    };

    return SizedBox.square(
      dimension: size,
      child: Transform.scale(
        scale: scale,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Transform.rotate(
                angle: tilt,
                child: CustomPaint(
                  painter: _BadgePainter(color: background, petal: petal),
                ),
              ),
            ),
            glyph,
          ],
        ),
      ),
    );
  }
}

/// 八瓣花瓣：r(θ) = R·(1 + 0.1·cos 8θ)，外接圆恰好是徽章尺寸
class _BadgePainter extends CustomPainter {
  _BadgePainter({required this.color, required this.petal});

  final Color color;
  final bool petal;

  static const _lobes = 8;
  static const _depth = 0.1;
  static const _samples = 160;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    if (!petal) {
      canvas.drawCircle(center, outer, paint);
      return;
    }
    final base = outer / (1 + _depth);
    final path = Path();
    for (var i = 0; i < _samples; i++) {
      final angle = i * 2 * math.pi / _samples;
      final r = base * (1 + _depth * math.cos(_lobes * angle));
      final point = center + Offset(r * math.cos(angle), r * math.sin(angle));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BadgePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.petal != petal;
}

/// 进度胶囊占住顶部时，普通提示整体下移让位；进度提示收尾后升回原位。
/// 进度提示自己不参与，免得把自己推下去。
class _StackSlot extends StatelessWidget {
  const _StackSlot({required this.active, required this.child});

  final bool active;
  final Widget child;

  /// 进度胶囊高度（内边距 8×2 + 徽章 40）再加上间距 12
  static const double _slotHeight = 68;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: ToastService._progressOnTop,
      builder: (context, shown, child) => TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: shown ? _slotHeight : 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        builder: (context, offset, child) =>
            Transform.translate(offset: Offset(0, offset), child: child),
        child: child,
      ),
      child: child,
    );
  }
}

/// 从徽章处的圆点横向展开：高度随内容，宽度在 [高度, 内容宽] 之间插值。
/// 未展开的部分由外层玻璃的圆角裁切。
class _WidthReveal extends SingleChildRenderObjectWidget {
  const _WidthReveal({required this.factor, required super.child});

  final double factor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWidthReveal(factor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWidthReveal renderObject,
  ) {
    renderObject.factor = factor;
  }
}

class _RenderWidthReveal extends RenderProxyBox {
  _RenderWidthReveal(this._factor);

  double _factor;
  set factor(double value) {
    if (value == _factor) return;
    _factor = value;
    markNeedsLayout();
  }

  Size _revealed(BoxConstraints constraints, Size natural) {
    final collapsed = math.min(natural.height, natural.width);
    return constraints.constrain(
      Size(lerpDouble(collapsed, natural.width, _factor)!, natural.height),
    );
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return _revealed(constraints, child.getDryLayout(constraints.loosen()));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = _revealed(constraints, child.size);
  }
}

class _CheckmarkPainter extends CustomPainter {
  final double progress;
  final Color color;

  _CheckmarkPainter({
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    // Centered coordinates for a checkmark icon that looks like the material one
    final start = Offset(size.width * 0.24, size.height * 0.52);
    final mid = Offset(size.width * 0.43, size.height * 0.71);
    final end = Offset(size.width * 0.77, size.height * 0.33);

    final pathLength1 = (mid - start).distance;
    final pathLength2 = (end - mid).distance;
    final totalLength = pathLength1 + pathLength2;

    final currentLength = totalLength * progress;

    if (currentLength <= pathLength1) {
      // Draw first segment (the short dive)
      final currentMid = Offset.lerp(start, mid, currentLength / pathLength1)!;
      path.moveTo(start.dx, start.dy);
      path.lineTo(currentMid.dx, currentMid.dy);
    } else {
      // Draw first segment full
      path.moveTo(start.dx, start.dy);
      path.lineTo(mid.dx, mid.dy);
      // Draw second segment (the long tail upwards)
      final remainingLength = currentLength - pathLength1;
      final currentEnd =
          Offset.lerp(mid, end, remainingLength / pathLength2)!;
      path.lineTo(currentEnd.dx, currentEnd.dy);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckmarkPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
