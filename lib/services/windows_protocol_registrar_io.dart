import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

/// 把自定义协议写入 HKCU\Software\Classes(免管理员),让系统浏览器能把
/// discourse:// / fluxdo:// 深链派发给 fluxdo.exe。
///
/// 幂等:重复调用只是覆写同样的值;exe 路径变化(升级/移动)时也借此自动修正。
/// 配套:windows/runner/main.cpp 里的 SendAppLinkToInstance 负责把深链启动的
/// 第二个进程转发给已运行实例(app_links 官方集成方式)。
Future<void> ensureWindowsProtocolsRegistered() async {
  if (!Platform.isWindows) return;
  for (final scheme in const ['discourse', 'fluxdo']) {
    try {
      _registerScheme(scheme);
    } catch (e) {
      debugPrint('[WindowsProtocol] 注册 $scheme:// 失败: $e');
    }
  }
}

void _registerScheme(String scheme) {
  final appPath = Platform.resolvedExecutable;
  final key = CURRENT_USER.create('Software\\Classes\\$scheme');
  try {
    // 名字为空 = 键的 (Default) 值
    key.setValue('', RegistryValue.string('URL:$scheme Protocol'));
    key.setValue('URL Protocol', const RegistryValue.string(''));
    final cmdKey = key.create('shell\\open\\command');
    try {
      cmdKey.setValue('', RegistryValue.string('"$appPath" "%1"'));
    } finally {
      cmdKey.close();
    }
  } finally {
    key.close();
  }
}
