import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// 弹层期间直接模糊原生内容与 Flutter 顶栏的完整合成图片。
/// 不对平台视图使用 BackdropFilter，避免原生合成器在顶栏边界拆分滤镜。
/// 只保留当前弹层的画面，不落盘、不保活页面；退出动画结束即释放。
class MiniAppModalBlur extends ChangeNotifier implements ValueListenable<bool> {
  ui.Image? _image;
  ui.Image? get image => _image;
  @override
  bool get value => _image != null;
  double get sigma => _leases.fold(
    0.0,
    (value, lease) => lease._sigma > value ? lease._sigma : value,
  );
  final _leases = <MiniAppModalFrameLease>{};
  Future<ui.Image?> Function()? _captureFrame;
  Timer? _retry;
  bool _pending = false, _needsCapture = false;
  int _retryCount = 0;
  int _epoch = 0;
  bool _disposed = false;
  final _strength = ValueNotifier<double>(0);
  void _sigmaChanged() => _strength.value = sigma;

  MiniAppModalFrameLease acquire(Future<ui.Image?> Function() capture) {
    final lease = MiniAppModalFrameLease._(this, _epoch);
    if (_disposed) return lease;
    _leases.add(lease);
    _captureFrame = capture;
    if (_image == null) {
      // 菜单不等待截图。慢帧只要仍属于当前弹层，完成后就参与统一模糊。
      _startCapture();
    }
    return lease;
  }

  /// 旋转、键盘收放后更新底图；新图到达前保留已模糊的画面，避免闪回清晰画面。
  void refresh() {
    if (_disposed || _leases.isEmpty) return;
    _needsCapture = true;
    _retry?.cancel();
    _retry = null;
    _startCapture();
  }

  void _startCapture() {
    final capture = _captureFrame;
    if (_disposed || _leases.isEmpty || _pending || capture == null) return;
    _retry?.cancel();
    _retry = null;
    _pending = true;
    _needsCapture = false;
    unawaited(_capture(capture, _epoch));
  }

  Future<void> _capture(Future<ui.Image?> Function() capture, int epoch) async {
    ui.Image? result;
    try {
      result = await capture();
    } catch (_) {
      // 恢复和布局期间原生视图可能暂不可截图，不因此永久关闭这次弹层的模糊。
    }
    if (_disposed || epoch != _epoch || _leases.isEmpty) {
      result?.dispose();
      return;
    }
    _pending = false;
    if (result != null) {
      final old = _image;
      _image = result;
      _retryCount = 0;
      notifyListeners();
      if (old != null) _disposeAfterFrame(old);
    }
    if (_needsCapture || result == null) {
      // 仅当前弹层需要画面时串行重试，退避至每秒一次，关闭即取消。
      // 避免两次短暂失败后，整次菜单再也没有模糊。
      final delay = _needsCapture
          ? Duration.zero
          : Duration(milliseconds: (80 * (1 << _retryCount)).clamp(80, 1000));
      if (_retryCount < 4) _retryCount++;
      _retry = Timer(delay, _startCapture);
    }
  }

  void _release(MiniAppModalFrameLease lease) {
    if (!_leases.remove(lease)) return;
    if (_leases.isEmpty) {
      reset();
    } else {
      _sigmaChanged();
    }
  }

  void reset() {
    _epoch++;
    _leases.clear();
    _strength.value = 0;
    _captureFrame = null;
    _retry?.cancel();
    _retry = null;
    _pending = _needsCapture = false;
    _retryCount = 0;
    final old = _image;
    _image = null;
    if (old != null) {
      if (!_disposed) notifyListeners();
      _disposeAfterFrame(old);
    }
  }

  void _disposeAfterFrame(ui.Image image) {
    // RawImage 在下一次 build 移除，等这一帧绘制结束再释放底层句柄。
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    _strength.dispose();
    super.dispose();
  }
}

class MiniAppModalFrameLease {
  MiniAppModalFrameLease._(this._owner, this._epoch);
  final MiniAppModalBlur _owner;
  final int _epoch;
  double _sigma = 0;
  bool _finished = false;

  bool get valid => !_owner._disposed && _owner._epoch == _epoch;
  bool get hasFrame => valid && _owner.image != null;

  void onBlurSigmaChanged(double sigma) {
    if (!valid || !sigma.isFinite) return;
    if (_sigma == sigma) return;
    _sigma = sigma;
    if (_finished && sigma <= 0) {
      _owner._release(this);
    } else {
      _owner._sigmaChanged();
    }
  }

  /// pop 返回时弹层仍在退场；等待真实模糊动画归零，支持菜单接续评分。
  void finish() {
    _finished = true;
    if (valid && _sigma <= 0) _owner._release(this);
  }
}

class MiniAppModalFrame extends StatelessWidget {
  const MiniAppModalFrame({super.key, required this.blur});
  final MiniAppModalBlur blur;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([blur, blur._strength]),
    builder: (context, _) => blur.image == null
        ? const SizedBox.shrink()
        : IgnorePointer(
            child: ExcludeSemantics(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: MediaQuery.maybeOf(context)?.disableAnimations == true
                    ? Duration.zero
                    : const Duration(milliseconds: 120),
                builder: (_, readiness, child) => ClipRect(
                  // 截图可能迟到，也可能与继续运行的网页已经不同。
                  // 淡入已模糊的画面，退场低模糊阶段淡回实时网页；不能在
                  // sigma 为零时仍用不透明的低清旧截图替换网页一帧。
                  child: Opacity(
                    opacity: readiness * (blur.sigma / 4).clamp(0.0, 1.0),
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: blur.sigma,
                        sigmaY: blur.sigma,
                        tileMode: ui.TileMode.clamp,
                      ),
                      child: child,
                    ),
                  ),
                ),
                child: RawImage(
                  image: blur.image,
                  fit: BoxFit.fill,
                  alignment: Alignment.topLeft,
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
          ),
  );
}
