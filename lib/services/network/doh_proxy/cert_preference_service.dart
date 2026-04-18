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

  /// iOS/macOS 必须使用 per-device CA
  /// macOS: WKWebView CONNECT 代理需要系统钥匙串信任，per-device CA 避免每次更新都要重新信任
  static bool get isPerDeviceRequired => Platform.isIOS || Platform.isMacOS;

  /// 非 iOS/macOS 平台 per-device 为可选项
  static bool get isPerDeviceOptional => !isPerDeviceRequired;

  /// 是否使用 per-device CA
  ///
  /// iOS/macOS 强制返回 true（平台要求），其他平台读取用户偏好
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
