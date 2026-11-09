import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';

/// 只把玻璃覆盖的小块原生画面送入 Flutter 合成树，不覆盖或暂停整个游戏。
typedef MiniAppGlassFrame = SurfaceFrame;
typedef MiniAppGlassCapture = SurfaceCapture;

class MiniAppGlassBackdrop extends StatefulWidget {
  const MiniAppGlassBackdrop({
    super.key,
    required this.capture,
    this.showBackdrop = true,
    this.enabled = true,
    this.onSample,
    this.captureBounds,
    this.builder,
  });
  final MiniAppGlassCapture capture;
  final bool showBackdrop, enabled;
  final ValueChanged<SurfaceColorSample>? onSample;

  /// 本地坐标下的最终覆盖区域，展开时一次取得完整菜单背景。
  final Rect? captureBounds;
  final Widget Function(BuildContext, Widget backdrop, double readiness)?
  builder;

  @override
  State<MiniAppGlassBackdrop> createState() => _MiniAppGlassBackdropState();
}

class _MiniAppGlassBackdropState extends State<MiniAppGlassBackdrop>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  MiniAppGlassFrame? _frame;
  Rect? _frameRequest;
  Timer? _timer;
  bool _pending = false;
  bool _foreground = true, _ticking = true;
  int _epoch = 0, _failures = 0;
  final _colorClock = Stopwatch();
  Duration _cost = Duration.zero;
  late final _frameFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  bool get _enabled => widget.enabled && _foreground && _ticking;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticking = TickerMode.valuesOf(context).enabled;
    if (_ticking != ticking) {
      _ticking = ticking;
      _restart();
    }
  }

  @override
  void didUpdateWidget(MiniAppGlassBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.showBackdrop != widget.showBackdrop) {
      // 暂停取样不等于清空画面；按住、吸附和短时遮挡保留当前小块底图。
      _restart(clear: !widget.showBackdrop);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _restart();
    if (mounted) setState(() {});
  }

  void _restart({bool clear = true}) {
    _epoch++;
    _timer?.cancel();
    if (clear) {
      final frame = _frame;
      _frame = null;
      _frameRequest = null;
      _frameFade.value = 0;
      if (frame != null) _disposeImage(frame.image);
    }
    if (_enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    }
  }

  Future<void> _capture() async {
    if (!mounted || _pending || !_enabled) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.hasSize || render.size.isEmpty) return;
    final region = widget.captureBounds ?? Offset.zero & render.size;
    final bounds = region.shift(render.localToGlobal(Offset.zero)).inflate(16);
    _pending = true;
    final epoch = _epoch;
    final clock = Stopwatch()..start();
    MiniAppGlassFrame? next;
    SurfaceColorSample? sample;
    try {
      next = await widget.capture(
        bounds,
        maxWidth: widget.showBackdrop ? 220 : 32,
      );
      // 玻璃与取色共享这一帧；展开时也不逐帧读回像素。
      if (next != null &&
          mounted &&
          epoch == _epoch &&
          widget.onSample != null &&
          (!_colorClock.isRunning || _colorClock.elapsedMilliseconds >= 800)) {
        sample = await AdaptiveSurfaceColors.fromImage(next.image);
        _colorClock
          ..reset()
          ..start();
      }
    } catch (_) {
      // 原生视图恢复期间可能暂不可截图，下一次取样继续；不阻塞操作。
    }
    _pending = false;
    _cost = clock.elapsed;
    if (!mounted) {
      next?.image.dispose();
      return;
    }
    if (epoch != _epoch || !_enabled) {
      next?.image.dispose();
      // 例如低频色样尚未返回时用户已展开；丢弃后立即补当前请求，
      // 不额外等待色样的 1.2 秒轮询间隔，仍始终只有一个截图在途。
      if (_enabled) _timer = Timer(Duration.zero, _capture);
      return;
    }
    _failures = next == null ? (_failures + 1).clamp(0, 4) : 0;
    if (sample != null) widget.onSample?.call(sample);
    if (!mounted || epoch != _epoch) {
      next?.image.dispose();
      return;
    }
    if (next != null && widget.showBackdrop) {
      final old = _frame;
      setState(() {
        _frame = next;
        _frameRequest = bounds;
      });
      // 只有首帧接入需要过渡；周期更新不能反复从透明开始，否则会脉冲闪烁。
      if (old == null) {
        if (MediaQuery.disableAnimationsOf(context)) {
          _frameFade.value = 1;
        } else {
          _frameFade.forward(from: 0);
        }
      }
      if (old != null) _disposeImage(old.image);
    } else {
      next?.image.dispose();
    }
    _schedule();
  }

  void _schedule() {
    if (!mounted || !_enabled) return;
    // 静止时每 1.2 秒取一张 32px 小图，不保留图像；慢设备按本次耗时退避。
    final base = widget.showBackdrop ? 160 : 1200;
    final delay = (_cost.inMilliseconds * 4).clamp(base, 2400);
    _timer?.cancel();
    _timer = Timer(
      Duration(milliseconds: (delay * (1 << _failures)).clamp(base, 5000)),
      _capture,
    );
  }

  void _disposeImage(ui.Image image) {
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frameFade.dispose();
    WidgetsBinding.instance.removeObserver(this);
    final frame = _frame;
    if (frame != null) _disposeImage(frame.image);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _frameFade,
      builder: (context, _) {
        final frame = widget.showBackdrop && _foreground && _ticking
            ? _frame
            : null;
        final backdrop = CustomPaint(
          painter: _BackdropPainter(
            frame,
            context,
            request: _frameRequest,
            target: widget.captureBounds?.inflate(16),
          ),
        );
        final readiness = frame == null ? 0.0 : _frameFade.value;
        return widget.builder?.call(context, backdrop, readiness) ??
            Opacity(opacity: readiness, child: backdrop);
      },
    ),
  );
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.frame, this.context, {this.request, this.target});
  final MiniAppGlassFrame? frame;
  final BuildContext context;
  final Rect? request, target;

  @override
  void paint(Canvas canvas, Size size) {
    final value = frame;
    final render = context.findRenderObject();
    if (value == null || render is! RenderBox) return;
    var destination = value.globalBounds.shift(
      -render.localToGlobal(Offset.zero),
    );
    final from = request, to = target;
    if (from != null && to != null && !from.isEmpty) {
      // 按住时不截图，底图随同一块玻璃平移；松手后再采当前位置。
      // 保留视口边缘裁切比例，不能把截掉的区域拉伸填满菜单。
      destination = Rect.fromLTWH(
        to.left + (value.globalBounds.left - from.left) * to.width / from.width,
        to.top + (value.globalBounds.top - from.top) * to.height / from.height,
        value.globalBounds.width * to.width / from.width,
        value.globalBounds.height * to.height / from.height,
      );
    }
    canvas.drawImageRect(
      value.image,
      Rect.fromLTWH(
        0,
        0,
        value.image.width.toDouble(),
        value.image.height.toDouble(),
      ),
      destination,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) => true;
}
