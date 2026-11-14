import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// 只向指定的 Android 浏览器实例传递网页仍需处理的安全区。
///
/// Flutter 的工具栏或留边已经承担的边，在原生层归零，避免网页的 env()
/// 再次避让。保活 ID 随原生实例保持不变，不会误改登录页或小程序。
abstract final class BrowserNativeSafeArea {
  static const _channel = MethodChannel('com.fluxdo/browser_safe_area');

  static Future<bool> apply({
    required String keepAliveId,
    required EdgeInsets unsafe,
    required bool edgeToEdge,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    final remaining = edgeToEdge ? unsafe : EdgeInsets.zero;
    try {
      return await _channel.invokeMethod<bool>('setHandledEdges', {
            'keepAliveId': keepAliveId,
            'left': remaining.left == 0,
            'top': remaining.top == 0,
            'right': remaining.right == 0,
            'bottom': remaining.bottom == 0,
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
