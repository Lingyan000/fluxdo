import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'cert_preference_service.dart';
import 'per_device_cert_service.dart';

/// Windows CA 证书信任服务
///
/// DoH 网关对 WebView2 流量做 MITM,签发证书的 CA 必须进入 Windows
/// 「当前用户 → 受信任的根证书颁发机构」,否则 WebView2 握手全部失败
/// (CF 验证/登录/Cookie 同步反复超时重试,表现为周期性卡顿)。
/// iOS 有描述文件引导、macOS 自动写钥匙串,Windows 此前没有任何引导。
///
/// 通过 `certutil -user` 操作,无需管理员权限;首次安装根证书时
/// Windows 会弹出系统级确认对话框,由用户最终确认。
class WindowsCertTrustService {
  WindowsCertTrustService._();
  static final WindowsCertTrustService instance = WindowsCertTrustService._();

  /// 当前生效的 CA PEM(per-device 开启时用设备证书,否则用内置 CA)
  Future<String?> _activeCaPem() async {
    if (await CertPreferenceService.usePerDevice()) {
      final certService = PerDeviceCertService.instance;
      if (certService.isLoaded || await certService.ensureCaCert()) {
        return certService.certPem;
      }
      return null;
    }
    try {
      final data = await rootBundle.load('assets/certs/proxy_ca.pem');
      return utf8.decode(data.buffer.asUint8List());
    } catch (e) {
      debugPrint('[WinCertTrust] 内置 CA 读取失败: $e');
      return null;
    }
  }

  /// 从 PEM 提取 DER 并计算 SHA-1 指纹(certutil 按指纹定位证书)
  String? _thumbprint(String pem) {
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
    ).firstMatch(pem);
    if (match == null) return null;
    try {
      final der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
      return sha1.convert(der).toString();
    } catch (e) {
      debugPrint('[WinCertTrust] CA PEM 解析失败: $e');
      return null;
    }
  }

  /// 当前 CA 是否已在用户根信任库中
  Future<bool> isInstalled() async {
    if (!Platform.isWindows) return true;
    final pem = await _activeCaPem();
    if (pem == null) return false;
    final thumbprint = _thumbprint(pem);
    if (thumbprint == null) return false;
    try {
      final result = await Process.run('certutil', [
        '-user',
        '-store',
        'Root',
        thumbprint,
      ]);
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[WinCertTrust] 查询信任库失败: $e');
      return false;
    }
  }

  /// 安装当前 CA 到用户根信任库(触发 Windows 系统确认对话框)
  Future<bool> install() async {
    if (!Platform.isWindows) return true;
    final pem = await _activeCaPem();
    if (pem == null) return false;
    File? tempFile;
    try {
      final tempDir = await getTemporaryDirectory();
      tempFile = File(
        '${tempDir.path}${Platform.pathSeparator}fluxdo_doh_ca.crt',
      );
      await tempFile.writeAsString(pem);
      final result = await Process.run('certutil', [
        '-user',
        '-addstore',
        'Root',
        tempFile.path,
      ]);
      if (result.exitCode != 0) {
        // 常见于用户在系统确认框里点了「否」
        debugPrint(
          '[WinCertTrust] 安装未完成 (exit=${result.exitCode}): '
          '${result.stdout}${result.stderr}',
        );
        return false;
      }
      debugPrint('[WinCertTrust] CA 已加入用户根信任库');
      return true;
    } catch (e) {
      debugPrint('[WinCertTrust] 安装失败: $e');
      return false;
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }
  }
}
