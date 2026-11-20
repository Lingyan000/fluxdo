import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 打开大图的指针。macOS 和 Windows 的 Flutter 引擎会把 zoomIn 映射成箭头。
MouseCursor get imageZoomCursor {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    return const _DesktopZoomCursor();
  }
  return SystemMouseCursors.zoomIn;
}

class _DesktopZoomCursor extends MouseCursor {
  const _DesktopZoomCursor();

  @override
  String get debugDescription => 'imageZoomIn';

  @override
  MouseCursorSession createSession(int device) => _ZoomSession(this, device);
}

class _ZoomSession extends MouseCursorSession {
  _ZoomSession(super.cursor, super.device);

  static const _channel = MethodChannel('com.fluxdo/image_cursor');

  @override
  Future<void> activate() => _channel.invokeMethod<void>('zoomIn');

  // 离开图片时 MouseTracker 会立即激活下一处命中的指针。
  @override
  void dispose() {}
}
