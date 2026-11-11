import 'package:flutter/services.dart';

import 'update_service.dart';

/// Flutter 保留现有更新入口，Sparkle 接管 macOS 下载、安装和重启。
class MacOSUpdateService {
  static const _channel = MethodChannel('com.fluxdo/macos_update');

  /// 启动提醒遵循 Sparkle 的“跳过此版本”，手动检查仍可安装该版本。
  static Future<bool> isVersionSkipped(String version) async {
    try {
      return await _channel.invokeMethod<bool>('isVersionSkipped', version) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkForUpdates() async {
    final proxy = await UpdateService.getGithubProxy();
    try {
      return await _channel.invokeMethod<bool>('checkForUpdates', {
            'githubProxy': proxy,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
