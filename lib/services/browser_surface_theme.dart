import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

/// 小程序与内置浏览器共用的边缘取色调度。仅记录颜色，不保留网页或截图。
class BrowserSurfaceTheme extends ChangeNotifier with WidgetsBindingObserver {
  BrowserSurfaceTheme() {
    WidgetsBinding.instance.addObserver(this);
  }

  Color? top, bottom;
  Color? _topCandidate, _bottomCandidate;
  SurfaceCapture? _capture;
  Rect? _bounds;
  Object? _document;
  bool _enabled = false, _pending = false, _disposed = false;
  int _epoch = 0, _failures = 0;
  Timer? _timer;

  bool get _running =>
      _enabled &&
      !_disposed &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  void configure({
    required bool enabled,
    required Object document,
    required Rect? bounds,
    required SurfaceCapture capture,
  }) {
    if (_disposed) return;
    _capture = capture;
    final changed =
        _document != document || _bounds != bounds || _enabled != enabled;
    if (_document != document) {
      top = bottom = _topCandidate = _bottomCandidate = null;
      _failures = 0;
      notifyListeners();
    }
    _document = document;
    _bounds = bounds;
    _enabled = enabled;
    if (changed) {
      _epoch++;
      _timer?.cancel();
      if (_running) _timer = Timer(const Duration(milliseconds: 180), _sample);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    _timer?.cancel();
    if (_running) _timer = Timer(const Duration(milliseconds: 180), _sample);
  }

  Future<void> _sample() async {
    if (!_running || _pending) return;
    final bounds = _bounds, capture = _capture;
    if (bounds == null || bounds.isEmpty || capture == null) return;
    _pending = true;
    final epoch = _epoch;
    final clock = Stopwatch()..start();
    var success = false;
    try {
      final height = bounds.height.clamp(1.0, 24.0);
      for (final isTop in [true, false]) {
        if (!_running || epoch != _epoch) break;
        final region = Rect.fromLTWH(
          bounds.left,
          isTop ? bounds.top : bounds.bottom - height,
          bounds.width,
          height,
        );
        final frame = await capture(region, maxWidth: 48);
        if (frame == null) continue;
        SurfaceColorSample? sample;
        try {
          sample = await AdaptiveSurfaceColors.fromImage(frame.image);
        } finally {
          frame.image.dispose();
        }
        if (!_running || epoch != _epoch || sample == null) break;
        success = true;
        // 参考 WebKit PageColorSampler 的稳定背景思路；沙箱内无法做 DOM
        // hit-test，改以色块覆盖率拒绝杂乱图片，保留上一次可靠的边缘颜色。
        if (sample.confidence < .45) continue;
        final old = isTop ? top : bottom;
        final candidate = isTop ? _topCandidate : _bottomCandidate;
        final next = sample.color;
        // 小变化不刷新 UI，大变化连续两次确认，避免游戏粒子或闪光染色。
        if (old == null ||
            (candidate != null && _distance(candidate, next) < .08)) {
          if (old == null || _distance(old, next) > .035) {
            if (isTop) {
              top = next;
            } else {
              bottom = next;
            }
            notifyListeners();
          }
        }
        if (isTop) {
          _topCandidate = next;
        } else {
          _bottomCandidate = next;
        }
      }
    } catch (_) {
      // 截图不可用时保留上次有效色，首次使用项目主题色。
    } finally {
      _pending = false;
      if (_running) {
        _failures = success ? 0 : (_failures + 1).clamp(0, 3);
        // 完成后才排下一轮；慢截图自动退避，不与交互争抢逐帧预算。
        final delay = (clock.elapsedMilliseconds * 5).clamp(2000, 6000);
        _timer = Timer(
          Duration(milliseconds: (delay * (1 << _failures)).clamp(2000, 12000)),
          _sample,
        );
      }
    }
  }

  double _distance(Color a, Color b) =>
      ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) / 3;

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// 同源普通网页读取入口。颜色解析交给浏览器，支持 CSS 色值和 media 条件。
/// 不遍历 iframe，不抓取 manifest，不向网页暴露原生能力。
const browserThemeColorScript = r'''(() => {
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext('2d', {willReadFrequently: true});
  if (!ctx) return null;
  for (const meta of document.querySelectorAll('meta[name="theme-color" i]')) {
    if (meta.media && !matchMedia(meta.media).matches) continue;
    const color = meta.content.trim();
    if (!color || !CSS.supports('color', color) || /currentcolor|var\(/i.test(color)) continue;
    ctx.clearRect(0, 0, 1, 1); ctx.fillStyle = color; ctx.fillRect(0, 0, 1, 1);
    const rgba = Array.from(ctx.getImageData(0, 0, 1, 1).data);
    if (rgba[3] === 255) return rgba;
  }
  return null;
})()''';
