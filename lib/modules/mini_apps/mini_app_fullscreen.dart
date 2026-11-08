import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

enum MiniAppOrientation { system, portrait, landscape }

/// 串行管理系统栏和屏幕方向；关闭页面后，迟到的操作不能重新锁屏或全屏。
class MiniAppFullscreen {
  // 独立 Windows 窗口必须操作所属 HWND，不能使用旧插件的主窗口查找。
  static Future<bool> Function()? windowIsFullscreen;
  static Future<void> Function(bool)? windowSetFullscreen;
  MiniAppFullscreen({this.restoreOrientations});

  final List<DeviceOrientation> Function()? restoreOrientations;
  Future<void> _pending = Future.value();
  bool? _previousWindowFullscreen;
  bool _closed = false, _orientationChanged = false, _uiChanged = false;

  bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _enqueue(Future<void> Function() action) =>
      _pending = _pending.catchError((_) {}).then((_) => action());

  Future<void> setFullscreen(bool value) {
    if (_closed) return _pending;
    return _enqueue(() => _setFullscreen(value));
  }

  Future<void> _setFullscreen(bool value) async {
    _uiChanged = true;
    if (_mobile) {
      if (value) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        // 先清除沉浸标记，再恢复项目默认的 edge-to-edge。
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    } else if (value) {
      _previousWindowFullscreen ??=
          await (windowIsFullscreen?.call() ?? windowManager.isFullScreen());
      await (windowSetFullscreen?.call(true) ??
          windowManager.setFullScreen(true));
    } else if (_previousWindowFullscreen != null) {
      await (windowSetFullscreen?.call(_previousWindowFullscreen!) ??
          windowManager.setFullScreen(_previousWindowFullscreen!));
      _previousWindowFullscreen = null;
    }
  }

  Future<void> setOrientation(MiniAppOrientation value) {
    if (_closed || !_mobile) return _pending;
    return _enqueue(() async {
      _orientationChanged = true;
      await SystemChrome.setPreferredOrientations(switch (value) {
        MiniAppOrientation.system => [],
        MiniAppOrientation.portrait => [DeviceOrientation.portraitUp],
        MiniAppOrientation.landscape => [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      });
    });
  }

  Future<void> restore() {
    if (_closed) return _pending;
    _closed = true;
    return _enqueue(_restoreDisplay);
  }

  /// 折叠运行面板时归还显示设置，但保留再次展开的控制能力。
  Future<void> suspend() {
    if (_closed) return _pending;
    return _enqueue(_restoreDisplay);
  }

  Future<void> _restoreDisplay() async {
    try {
      if (_uiChanged) await _setFullscreen(false);
    } finally {
      if (_mobile && _orientationChanged) {
        await SystemChrome.setPreferredOrientations(
          restoreOrientations?.call() ?? [],
        );
      }
      _orientationChanged = false;
      _uiChanged = false;
    }
  }
}
