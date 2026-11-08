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
  });
  final MiniAppGlassCapture capture;
  final bool showBackdrop, enabled;
  final ValueChanged<SurfaceColorSample>? onSample;

  @override
  State<MiniAppGlassBackdrop> createState() => _MiniAppGlassBackdropState();
}

class _MiniAppGlassBackdropState extends State<MiniAppGlassBackdrop>
    with WidgetsBindingObserver {
  MiniAppGlassFrame? _frame;
  Timer? _timer;
  bool _pending = false;
  bool _foreground = true, _ticking = true;
  int _epoch = 0, _failures = 0;
  final _colorClock = Stopwatch();
  Duration _cost = Duration.zero;
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
      _restart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _restart();
    if (mounted) setState(() {});
  }

  void _restart() {
    _epoch++;
    _timer?.cancel();
    final frame = _frame;
    _frame = null;
    if (frame != null) _disposeImage(frame.image);
    if (_enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    }
  }

  Future<void> _capture() async {
    if (!mounted || _pending || !_enabled) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.hasSize || render.size.isEmpty) return;
    final bounds = (render.localToGlobal(Offset.zero) & render.size).inflate(
      16,
    );
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
      _schedule();
      return;
    }
    _failures = next == null ? (_failures + 1).clamp(0, 4) : 0;
    if (sample != null) widget.onSample?.call(sample);
    if (next != null && widget.showBackdrop) {
      final old = _frame;
      setState(() => _frame = next);
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
    WidgetsBinding.instance.removeObserver(this);
    final frame = _frame;
    if (frame != null) _disposeImage(frame.image);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _BackdropPainter(
        widget.showBackdrop && _enabled ? _frame : null,
        context,
      ),
    ),
  );
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.frame, this.context);
  final MiniAppGlassFrame? frame;
  final BuildContext context;

  @override
  void paint(Canvas canvas, Size size) {
    final value = frame;
    final render = context.findRenderObject();
    if (value == null || render is! RenderBox) return;
    final destination = value.globalBounds.shift(
      -render.localToGlobal(Offset.zero),
    );
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
