import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cert_preference_service.dart';
import 'per_device_cert_service.dart';

/// Proxy CA certificate management
///
/// 配置 WebView 所需的代理 CA，不扩展 Dart 网络请求的全局信任。
class ProxyCertificate {
  ProxyCertificate._();

  static bool _initialized = false;

  /// macOS: CA 是否已在钥匙串中被信任
  static bool _macOsKeychainTrusted = false;

  /// 初始化设备证书和平台 WebView 信任入口
  ///
  /// Call this early in app startup (e.g., in main.dart)
  static Future<void> initialize() async {
    if (_initialized) return;

    final usePerDevice = await CertPreferenceService.usePerDevice();

    if (usePerDevice) {
      // per-device CA 证书（iOS/macOS 强制，其他平台可选）
      await _initializePerDevice();
    }

    _initialized = true;
  }

  /// 重新初始化（切换 per-device 开关后调用）
  static Future<void> reinitialize() async {
    _initialized = false;
    await initialize();
  }

  /// macOS: 检查 CA 是否在钥匙串中被信任
  ///
  /// 用于 DOH 启用前的检查。如果未信任，尝试重新添加。
  /// 返回 true 表示已信任或不需要钥匙串信任（非 macOS 平台）。
  static Future<bool> ensureKeychainTrust() async {
    if (!Platform.isMacOS) return true;

    // 先查询当前状态
    if (await _checkCaTrustedInKeychain()) {
      _macOsKeychainTrusted = true;
      return true;
    }

    // 未信任，尝试重新发送证书到原生层（触发钥匙串添加）
    final certService = PerDeviceCertService.instance;
    if (!certService.isLoaded) {
      await certService.ensureCaCert();
    }
    if (certService.certPem != null) {
      _macOsKeychainTrusted = await _sendCaCertToNative(certService.certPem!);
      return _macOsKeychainTrusted;
    }
    return false;
  }

  /// macOS: CA 钥匙串信任状态（内存缓存，避免频繁调用原生）
  static bool get isMacOsKeychainTrusted =>
      !Platform.isMacOS || _macOsKeychainTrusted;

  /// 初始化 per-device CA 证书（全平台通用）
  static Future<void> _initializePerDevice() async {
    final certService = PerDeviceCertService.instance;
    final ok = await certService.ensureCaCert();
    if (ok && certService.certPem != null) {
      // iOS: 将 CA 发送到原生层（swizzle 需要在 WebView 创建前设置）
      if (Platform.isIOS) {
        await _sendCaCertToNative(certService.certPem!);
      }
      // macOS: 不在启动时添加钥匙串，等 DOH 开启时由 ensureKeychainTrust() 处理
    } else {
      debugPrint('ProxyCertificate: per-device CA not ready');
    }
  }

  static const _proxyCertChannel = MethodChannel('com.fluxdo/proxy_cert');

  /// 将 CA 证书发送到原生层，返回是否信任成功
  static Future<bool> _sendCaCertToNative(String pem) async {
    try {
      final result = await _proxyCertChannel.invokeMethod<bool>('setCaCertPem', pem);
      debugPrint('ProxyCertificate: CA cert sent to native, trusted=$result');
      return result ?? false;
    } catch (e) {
      debugPrint('ProxyCertificate: Failed to send CA cert to native: $e');
      return false;
    }
  }

  /// macOS: 查询原生层 CA 是否在钥匙串中被信任
  static Future<bool> _checkCaTrustedInKeychain() async {
    try {
      final result = await _proxyCertChannel.invokeMethod<bool>('isCaTrusted');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Get the CA certificate PEM content for display or export
  static Future<String?> getCertificatePem() async {
    final usePerDevice = await CertPreferenceService.usePerDevice();
    if (usePerDevice) {
      final certService = PerDeviceCertService.instance;
      if (certService.isLoaded) return certService.certPem;
      await certService.ensureCaCert();
      return certService.certPem;
    }
    try {
      return await rootBundle.loadString('assets/certs/proxy_ca.pem');
    } catch (e) {
      return null;
    }
  }
}
