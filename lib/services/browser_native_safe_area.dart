import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 为指定的 Android 浏览器实例安装原生几何观察器。
///
/// 原生层按 WebView 与窗口的实际重叠处理 Insets，无需同步工具栏显隐开关。
/// 保活恢复及全屏切换时再次调用会刷新已有观察器，不会重复注册。
abstract final class BrowserNativeSafeArea {
  static const _channel = MethodChannel('com.fluxdo/browser_safe_area');

  static Future<bool> attach({required String keepAliveId}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _channel.invokeMethod<bool>('attach', {
            'keepAliveId': keepAliveId,
          }) ??
          false;
    } on PlatformException catch (error) {
      debugPrint('浏览器安全区同步失败：$error');
      return false;
    } on MissingPluginException catch (error) {
      debugPrint('浏览器安全区通道不可用：$error');
      return false;
    }
  }
}
