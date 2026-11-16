import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/net_core_service.dart';

/// Per-device CA 证书管理服务
///
/// 每台设备生成唯一的 CA 证书，避免所有用户共享同一私钥。
/// 全平台可用：iOS 强制启用，其他平台通过 CertPreferenceService 可选启用。
/// installProfile() / _buildMobileConfig() 仅 iOS 调用。
class PerDeviceCertService {
  PerDeviceCertService._();
  static final PerDeviceCertService instance = PerDeviceCertService._();

  @visibleForTesting
  PerDeviceCertService.forTesting({
    required Future<Directory> Function() certsDirectory,
    required ({String certPem, String keyPem})? Function() generateCa,
  }) : _directoryProvider = certsDirectory, _generator = generateCa;

  Future<Directory> Function()? _directoryProvider;
  ({String certPem, String keyPem})? Function()? _generator;
  Future<void> _operations = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static const _certInstalledKey = 'per_device_cert_installed';

  String? _certPem;
  String? _keyPem;
  bool _loaded = false;

  /// 获取 CA 证书 PEM
  String? get certPem => _certPem;

  /// 获取 CA 私钥 PEM
  String? get keyPem => _keyPem;

  /// 证书是否已加载
  bool get isLoaded => _loaded && _certPem != null && _keyPem != null;

  /// 确保 CA 证书存在（有则读取，无则生成并存储）
  Future<bool> ensureCaCert() => _serialized(_ensureCaCert);

  Future<bool> _ensureCaCert() async {
    if (isLoaded) return true;

    final dir = await _certsDir();
    final certFile = File('${dir.path}/ca.crt');
    final keyFile = File('${dir.path}/ca.key');
    final bundle = File('${dir.path}/ca.json');
    String cert;
    String key;

    if (await bundle.exists()) {
      // 损坏时保留现场，不能悄悄换掉用户已经安装到系统的信任锚点。
      try {
        final data = jsonDecode(await bundle.readAsString()) as Map<String, dynamic>;
        if (data['version'] != 1) return false;
        cert = data['certPem'] as String;
        key = data['keyPem'] as String;
        if (cert.trim().isEmpty || key.trim().isEmpty) return false;
      } catch (_) {
        debugPrint('[PerDeviceCert] CA 存储损坏，需显式重新生成并安装');
        return false;
      }
    } else {
      final hasCert = await certFile.exists();
      final hasKey = await keyFile.exists();
      if (hasCert != hasKey) {
        debugPrint('[PerDeviceCert] CA 证书与私钥文件不完整');
        return false;
      }
      if (hasCert) {
        cert = await certFile.readAsString();
        key = await keyFile.readAsString();
        if (cert.trim().isEmpty || key.trim().isEmpty) return false;
      } else {
        final result = _generator != null ? _generator!() : NetCoreService.instance.generateCa();
        if (result == null) {
          debugPrint('[PerDeviceCert] CA 生成失败');
          return false;
        }
        cert = result.certPem;
        key = result.keyPem;
      }
      await dir.create(recursive: true);
      final temporary = File('${bundle.path}.tmp');
      await temporary.writeAsString(jsonEncode({
        'version': 1, 'certPem': cert, 'keyPem': key,
      }), flush: true);
      await temporary.rename(bundle.path);
      // 新格式原子保存整对材料，旧格式仅在成功迁移后清理。
      if (hasCert) {
        await certFile.delete();
        await keyFile.delete();
      }
    }

    _certPem = cert;
    _keyPem = key;
    _loaded = true;
    debugPrint('[PerDeviceCert] CA 证书与私钥已就绪');
    return true;
  }

  static const _profileChannel = MethodChannel('com.fluxdo/profile_install');

  /// 通过原生层安装描述文件
  ///
  /// 原生层启动 HTTP server + 后台保活 + 打开 Safari 下载 .mobileconfig
  Future<bool> installProfile() async {
    if (!isLoaded) {
      final ok = await ensureCaCert();
      if (!ok) return false;
    }

    try {
      final cert = _certPem;
      if (cert == null) return false;
      final mobileconfig = _buildMobileConfig(cert);
      final success = await _profileChannel.invokeMethod<bool>(
        'installProfile',
        mobileconfig,
      );
      debugPrint('[PerDeviceCert] 原生安装结果: $success');
      return success ?? false;
    } catch (e) {
      debugPrint('[PerDeviceCert] 描述文件安装失败: $e');
      return false;
    }
  }

  /// 检查用户是否已标记证书为已安装
  Future<bool> isCertInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_certInstalledKey) ?? false;
  }

  /// 标记证书为已安装
  Future<void> markCertInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_certInstalledKey, true);
  }

  /// 清除已安装标记（用于重新安装）
  Future<void> clearCertInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_certInstalledKey);
  }

  /// 重置内存状态并删除已有证书文件，下次 ensureCaCert 会重新生成
  Future<void> reset() => _serialized(() async {
    _certPem = null;
    _keyPem = null;
    _loaded = false;
    await clearCertInstalled();
    try {
      final dir = await _certsDir();
      final certFile = File('${dir.path}/ca.crt');
      final keyFile = File('${dir.path}/ca.key');
      final bundle = File('${dir.path}/ca.json');
      final temporary = File('${bundle.path}.tmp');
      if (await bundle.exists()) await bundle.delete();
      if (await temporary.exists()) await temporary.delete();
      if (certFile.existsSync()) await certFile.delete();
      if (keyFile.existsSync()) await keyFile.delete();
    } catch (_) {}
  });

  Future<Directory> _certsDir() async {
    if (_directoryProvider != null) return _directoryProvider!();
    final appSupport = await getApplicationSupportDirectory();
    return Directory('${appSupport.path}/certs');
  }

  /// 生成 .mobileconfig XML
  String _buildMobileConfig(String certPem) {
    // 从 PEM 中提取 base64 编码的证书数据
    final lines = certPem.split('\n')
        .where((line) => !line.startsWith('-----') && line.trim().isNotEmpty)
        .join('');

    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadCertificateFileName</key>
            <string>DOH_Proxy_CA.cer</string>
            <key>PayloadContent</key>
            <data>$lines</data>
            <key>PayloadDescription</key>
            <string>DOH Proxy CA Certificate</string>
            <key>PayloadDisplayName</key>
            <string>DOH Proxy CA</string>
            <key>PayloadIdentifier</key>
            <string>com.fluxdo.doh-proxy-ca.cert</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>A1B2C3D4-E5F6-7890-ABCD-EF1234567890</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>安装此证书以启用 DOH Proxy 的 HTTPS 拦截功能</string>
    <key>PayloadDisplayName</key>
    <string>DOH Proxy CA</string>
    <key>PayloadIdentifier</key>
    <string>com.fluxdo.doh-proxy-ca</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>F1E2D3C4-B5A6-7890-1234-567890ABCDEF</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>''';
  }
}
