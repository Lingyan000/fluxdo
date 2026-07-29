import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'media_overlay_style.dart';

/// 自绘视频进度条:轨道 / 缓冲段(可能多段)/ 已播三层 + 拖动把手。
///
/// 两档形态(跟随 M3eFlags):
/// - [expressive] = true:M3 Expressive 媒体形态 —— 已播段为流动波浪线
///   (播放中相位流动、暂停时抚平)、竖条把手、把手两侧轨道留缺口、
///   轨道末端停止点。波浪动画只在「播放中且控制条可见」时跑,
///   隐藏即停表,不给滚动/静息帧添负担。
/// - false:经典细条(圆点把手)。
///
/// 质感细节:
/// - 悬停(桌面)/拖动时轨道平滑变粗、把手放大(经典档带柔光晕);
/// - 拖动中显示时间气泡;桌面端纯悬停也显示落点预览气泡;
/// - 所有形变走 [AnimationController] 插值,无状态硬切。
///
/// 交互正确性(修过的坑,别回退):
/// - 不挂 onTapDown/onTapCancel —— tap 与 horizontal drag 同场竞技时,
///   拖动胜出会先派发 tapCancel 再 dragStart,若 tapDown 已写入拖动态,
///   tapCancel 的清理会让进度条闪回真实位置一帧。纯点击只用 onTapUp。
/// - 松手提交后展示值不立即交还 controller:seekTo 是异步的,position
///   完成前仍回报旧值,立即交还会「弹回原位再跳目标」。pending 钉住
///   目标位,等 position 追上(差 < 800ms)或 2s 兜底再交还。
class MediaProgressBar extends StatefulWidget {
  const MediaProgressBar({
    super.key,
    required this.value,
    required this.onSeek,
    this.onDragActive,
    this.hoverPreviewEnabled = true,
    this.expressive = false,
  });

  final VideoPlayerValue value;
  final ValueChanged<Duration> onSeek;

  /// 拖动开始/结束回调(控制层用来暂停自动隐藏计时)。
  final ValueChanged<bool>? onDragActive;

  /// 悬停预览气泡开关,同时也是「控制条可见」的代理信号(波浪动画
  /// 据此启停)。控制条隐藏(IgnorePointer)期间 MouseRegion 收不到
  /// onExit,悬停态会卡死残留 —— 控制层在隐藏时传 false,本组件借
  /// didUpdateWidget 强制清理。
  final bool hoverPreviewEnabled;

  /// M3 Expressive 形态开关(M3eFlags.enabled)。
  final bool expressive;

  @override
  State<MediaProgressBar> createState() => _MediaProgressBarState();
}

class _MediaProgressBarState extends State<MediaProgressBar>
    with TickerProviderStateMixin {
  /// 拖动中的预览进度(0-1),null = 未在拖动。
  double? _dragFraction;

  /// 已提交 seek、等待 position 追上目标期间的展示保持值(0-1)。
  double? _pendingFraction;
  Timer? _pendingTimeout;

  /// 桌面端悬停落点(0-1),驱动预览气泡;null = 未悬停。
  double? _hoverFraction;

  /// 0 → 1:静息 → 强调(变粗/把手放大),悬停或拖动时正向。
  late final AnimationController _emphasis = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );

  /// 波浪相位(循环 0→1),仅 expressive && 播放中 && 可见时 repeat。
  late final AnimationController _wavePhase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 波浪振幅(0=抚平/暂停,1=满幅/播放),平滑过渡。
  late final AnimationController _waveAmp = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  Duration get _duration => widget.value.duration;

  double get _playedFraction {
    final total = _duration.inMilliseconds;
    if (total == 0) return 0;
    return (widget.value.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _fractionToPosition(double fraction) => Duration(
        milliseconds: (_duration.inMilliseconds * fraction).round(),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void initState() {
    super.initState();
    _syncWave();
  }

  @override
  void didUpdateWidget(covariant MediaProgressBar old) {
    super.didUpdateWidget(old);
    // 控制条隐藏 → 清理悬停残留(onExit 在 IgnorePointer 下不会来)
    if (!widget.hoverPreviewEnabled && _hoverFraction != null) {
      _hoverFraction = null;
      _syncEmphasis();
    }
    _syncWave();
    // position 追上 seek 目标 → pending 使命完成,交还给实时值
    final pending = _pendingFraction;
    if (pending != null) {
      final target = _fractionToPosition(pending);
      final diffMs =
          (widget.value.position - target).inMilliseconds.abs();
      if (diffMs < 800) {
        _pendingTimeout?.cancel();
        _pendingTimeout = null;
        setState(() => _pendingFraction = null);
      }
    }
  }

  @override
  void dispose() {
    _pendingTimeout?.cancel();
    _emphasis.dispose();
    _wavePhase.dispose();
    _waveAmp.dispose();
    super.dispose();
  }

  /// 波浪动画启停:播放中且可见才流动,暂停/隐藏时抚平并停表。
  void _syncWave() {
    if (!widget.expressive) return;
    final animate = widget.value.isPlaying && widget.hoverPreviewEnabled;
    if (animate) {
      if (!_wavePhase.isAnimating) _wavePhase.repeat();
      _waveAmp.forward();
    } else {
      _wavePhase.stop();
      _waveAmp.reverse();
    }
  }

  void _updateDrag(Offset localPosition, double width) {
    setState(() {
      _dragFraction = (localPosition.dx / width).clamp(0.0, 1.0);
    });
  }

  void _commitSeek(double fraction) {
    _pendingTimeout?.cancel();
    setState(() {
      _dragFraction = null;
      _pendingFraction = fraction;
    });
    // 兜底:后端迟迟不回报新位置(或 seek 静默失败)也不能永远钉住展示
    _pendingTimeout = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pendingFraction = null);
    });
    widget.onSeek(_fractionToPosition(fraction));
  }

  void _syncEmphasis() {
    final active = _dragFraction != null || _hoverFraction != null;
    if (active) {
      _emphasis.forward();
    } else {
      _emphasis.reverse();
    }
  }

  Widget _timeBubble(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: MediaOverlayStyle.pill(radius: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: MediaOverlayStyle.foreground,
          fontSize: 12,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fraction =
            _dragFraction ?? _pendingFraction ?? _playedFraction;
        // 气泡:拖动中显示拖动位置;否则(桌面)悬停显示落点预览
        final bubbleFraction = _dragFraction ??
            (widget.hoverPreviewEnabled ? _hoverFraction : null);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (event) {
            if (!widget.hoverPreviewEnabled) return;
            setState(() {
              _hoverFraction =
                  (event.localPosition.dx / width).clamp(0.0, 1.0);
            });
            _syncEmphasis();
          },
          onExit: (_) {
            setState(() => _hoverFraction = null);
            _syncEmphasis();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) {
              widget.onDragActive?.call(true);
              _updateDrag(details.localPosition, width);
              _syncEmphasis();
            },
            onHorizontalDragUpdate: (details) =>
                _updateDrag(details.localPosition, width),
            onHorizontalDragEnd: (_) {
              final fraction = _dragFraction;
              if (fraction != null) _commitSeek(fraction);
              widget.onDragActive?.call(false);
              _syncEmphasis();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragFraction = null);
              widget.onDragActive?.call(false);
              _syncEmphasis();
            },
            onTapUp: (details) {
              _commitSeek(
                  (details.localPosition.dx / width).clamp(0.0, 1.0));
              widget.onDragActive?.call(false);
            },
            child: SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedBuilder(
                    animation: Listenable.merge(
                        [_emphasis, _wavePhase, _waveAmp]),
                    builder: (context, _) => CustomPaint(
                      size: Size(width, 28),
                      painter: _ProgressPainter(
                        played: fraction,
                        buffered: widget.value.buffered,
                        duration: _duration,
                        emphasis: Curves.easeOut.transform(_emphasis.value),
                        expressive: widget.expressive,
                        wavePhase: _wavePhase.value,
                        waveAmp:
                            Curves.easeOut.transform(_waveAmp.value),
                      ),
                    ),
                  ),
                  if (bubbleFraction != null)
                    Positioned(
                      left:
                          (bubbleFraction * width - 28).clamp(0.0, width - 56),
                      bottom: 26,
                      child: _timeBubble(
                          _fmt(_fractionToPosition(bubbleFraction))),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  const _ProgressPainter({
    required this.played,
    required this.buffered,
    required this.duration,
    required this.emphasis,
    this.expressive = false,
    this.wavePhase = 0,
    this.waveAmp = 0,
  });

  final double played;
  final List<DurationRange> buffered;
  final Duration duration;

  /// 0 = 静息,1 = 悬停/拖动强调态,中间值为过渡帧。
  final double emphasis;

  /// M3 Expressive 形态(波浪已播段 + 竖条把手 + 轨道缺口 + 尾点)。
  final bool expressive;

  /// 波浪相位(0-1 循环)与振幅系数(0=平,1=满)。
  final double wavePhase;
  final double waveAmp;

  static const _trackColor = Color(0x42FFFFFF);
  static const _bufferColor = Color(0x73FFFFFF);
  static const _playedColor = Colors.white;

  static const double _wavelength = 22;
  static const double _maxAmplitude = 2.4;

  @override
  void paint(Canvas canvas, Size size) {
    if (expressive) {
      _paintExpressive(canvas, size);
    } else {
      _paintClassic(canvas, size);
    }
  }

  /// M3 Expressive:已播波浪线 + 竖条把手(两侧留缺口)+ 直线余轨 + 尾点。
  void _paintExpressive(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final strokeWidth = 3.5 + 1.0 * emphasis;
    final playedX = size.width * played;
    final gap = 6.0 + 1.5 * emphasis;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // 余轨(把手右缺口 → 末端),直线
    final remStart = math.min(playedX + gap, size.width);
    if (remStart < size.width - 1) {
      stroke.color = _trackColor;
      canvas.drawLine(
          Offset(remStart, centerY), Offset(size.width - 4, centerY), stroke);
    }

    // 缓冲段叠在余轨上(直线,略亮)
    final totalMs = duration.inMilliseconds;
    if (totalMs > 0) {
      stroke.color = _bufferColor;
      for (final range in buffered) {
        final start = math.max(
            size.width * (range.start.inMilliseconds / totalMs), remStart);
        final end = math.min(
            size.width * (range.end.inMilliseconds / totalMs),
            size.width - 4);
        if (end > start + 1) {
          canvas.drawLine(
              Offset(start, centerY), Offset(end, centerY), stroke);
        }
      }
    }

    // 末端停止点(M3E 媒体签名细节)
    final dot = Paint()..color = _playedColor.withValues(alpha: 0.9);
    canvas.drawCircle(Offset(size.width - 2, centerY), 2, dot);

    // 已播段:波浪(播放中流动,暂停/隐藏时 waveAmp→0 抚平为直线)
    final playedEnd = math.max(playedX - gap, 0.0);
    if (playedEnd > 1) {
      stroke.color = _playedColor;
      final amp = _maxAmplitude * waveAmp;
      if (amp < 0.15) {
        canvas.drawLine(
            Offset(0, centerY), Offset(playedEnd, centerY), stroke);
      } else {
        final path = Path();
        // 相位以 playedX 为锚(波形跟着播放头走,而不是原点),
        // 波峰在把手处收敛更自然
        double yAt(double x) =>
            centerY +
            amp *
                math.sin(
                    ((x - playedX) / _wavelength + wavePhase) * 2 * math.pi);
        path.moveTo(0, yAt(0));
        for (double x = 2; x < playedEnd; x += 2) {
          path.lineTo(x, yAt(x));
        }
        path.lineTo(playedEnd, yAt(playedEnd));
        canvas.drawPath(path, stroke);
      }
    }

    // 竖条把手(M3E year2023 同款)
    final thumbW = 4.0 + 1.0 * emphasis;
    final thumbH = 16.0 + 6.0 * emphasis;
    final fill = Paint()..color = _playedColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(playedX, centerY),
            width: thumbW,
            height: thumbH),
        Radius.circular(thumbW / 2),
      ),
      fill,
    );
  }

  /// 经典形态:圆角矩形三层 + 圆点把手(M3E 关闭时)。
  void _paintClassic(Canvas canvas, Size size) {
    final trackHeight = 2.5 + 1.5 * emphasis;
    final centerY = size.height / 2;
    final radius = Radius.circular(trackHeight / 2);
    final paint = Paint();

    RRect trackRect(double startFraction, double endFraction) =>
        RRect.fromLTRBR(
          size.width * startFraction,
          centerY - trackHeight / 2,
          size.width * endFraction,
          centerY + trackHeight / 2,
          radius,
        );

    // 轨道
    paint.color = _trackColor;
    canvas.drawRRect(trackRect(0, 1), paint);

    // 缓冲段(可能多段)
    final totalMs = duration.inMilliseconds;
    if (totalMs > 0) {
      paint.color = _bufferColor;
      for (final range in buffered) {
        final start = (range.start.inMilliseconds / totalMs).clamp(0.0, 1.0);
        final end = (range.end.inMilliseconds / totalMs).clamp(0.0, 1.0);
        if (end > start) {
          canvas.drawRRect(trackRect(start, end), paint);
        }
      }
    }

    // 已播
    paint.color = _playedColor;
    canvas.drawRRect(trackRect(0, played), paint);

    // 把手:柔光晕(强调态渐显)+ 实心圆
    final thumbCenter = Offset(size.width * played, centerY);
    if (emphasis > 0) {
      paint
        ..color = Colors.white.withValues(alpha: 0.22 * emphasis)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(thumbCenter, 10 * emphasis, paint);
      paint.maskFilter = null;
    }
    paint.color = _playedColor;
    canvas.drawCircle(thumbCenter, 5 + 2.5 * emphasis, paint);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.duration != duration ||
      old.emphasis != emphasis ||
      old.expressive != expressive ||
      old.wavePhase != wavePhase ||
      old.waveAmp != waveAmp;
}
