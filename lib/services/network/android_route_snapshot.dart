import 'dart:io';

import 'package:flutter/services.dart';

/// 失败时读取 Android 为本应用公布的默认网络与目标路由。仅用于诊断。
Future<String> androidRouteSnapshot(List<InternetAddress> candidates) async {
  if (!Platform.isAndroid) return '';
  try {
    const channel = MethodChannel('com.fluxdo/network_route');
    final result = await channel
        .invokeMethod<String>('snapshot', [
          for (final address in candidates) address.rawAddress,
        ])
        .timeout(const Duration(milliseconds: 400));
    return result ?? 'appNetwork=unknown';
  } catch (_) {
    // 无 Activity、通道不可用或系统网络切换不能遮蔽原始连接异常。
    return 'appNetwork=unknown';
  }
}
