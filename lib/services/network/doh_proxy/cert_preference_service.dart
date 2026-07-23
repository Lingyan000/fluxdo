import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 证书偏好服务
///
/// 管理是否使用 per-device CA 证书的偏好设置。
/// iOS 强制使用 per-device CA（Network.framework 限制），
/// 其他平台可选启用。
class CertPreferenceService {
  CertPreferenceService._();

  static const _usePerDeviceKey = 'cert_use_per_device';

  /// iOS/macOS/Windows 必须使用 per-device CA
  /// macOS: WKWebView CONNECT 代理需要系统钥匙串信任，per-device CA 避免每次更新都要重新信任
  /// Windows: 网关 CA 需进入用户根信任库(系统级信任,作用于所有应用)。
  /// 内置 CA 私钥嵌在随包分发的 doh_proxy 二进制里可被提取,同构建用户共享
  /// 同一把——绝不能进系统信任库;强制本机现生成、私钥不出本机的设备证书。
  static bool get isPerDeviceRequired =>
      Platform.isIOS || Platform.isMacOS || Platform.isWindows;

  /// 其余平台 per-device 为可选项
  static bool get isPerDeviceOptional => !isPerDeviceRequired;

  /// 是否使用 per-device CA
  ///
  /// iOS/macOS/Windows 强制返回 true（平台要求），其他平台读取用户偏好
  static Future<bool> usePerDevice() async {
    if (isPerDeviceRequired) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_usePerDeviceKey) ?? false;
  }

  /// 设置是否使用 per-device CA（仅对非 iOS/macOS 平台生效）
  static Future<void> setUsePerDevice(bool value) async {
    if (isPerDeviceRequired) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_usePerDeviceKey, value);
  }
}
