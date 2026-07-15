import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

/// 检测操作系统层面的"系统代理"设置（区别于 VPN 虚拟网卡）。
///
/// Windows 下系统代理（设置里手动配的 HTTP 代理，或 Clash/V2rayN 等工具的
/// "设置为系统代理"模式，均不建虚拟网卡）写在
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`：
/// `ProxyEnable`（DWORD，1 表示已启用）+ `ProxyServer`（字符串），
/// 或 `AutoConfigURL`（PAC 自动代理脚本）。
/// 这是 WinINet/WinHTTP 系统代理的标准存放位置，IE/Edge/大多数拿系统代理
/// 的工具均读写这里。仅 Windows 实现；其余平台恒返回 false。
/// 系统代理注册表配置快照。
class SystemProxyConfig {
  const SystemProxyConfig({this.proxyUrl, this.pacUrl});

  /// 解析出的固定代理地址（`http://host:port` / `socks5://host:port`）。
  /// 注册表未启用固定代理时为 null。
  final String? proxyUrl;

  /// PAC 脚本地址。PAC 无法在 Dart 侧求值，只用于「系统代理已启用」判定。
  final String? pacUrl;

  bool get isEnabled => proxyUrl != null || (pacUrl?.isNotEmpty ?? false);

  @override
  bool operator ==(Object other) =>
      other is SystemProxyConfig &&
      other.proxyUrl == proxyUrl &&
      other.pacUrl == pacUrl;

  @override
  int get hashCode => Object.hash(proxyUrl, pacUrl);
}

class SystemProxyDetector {
  const SystemProxyDetector._();

  static const _keyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  /// 当前系统代理是否已启用。
  static bool isEnabled() => read().isEnabled;

  /// 读取系统代理完整配置。非 Windows 平台恒返回空配置。
  static SystemProxyConfig read() {
    if (!Platform.isWindows) return const SystemProxyConfig();
    try {
      final key = Registry.openPath(RegistryHive.currentUser, path: _keyPath);
      try {
        final enabled = key.getIntValue('ProxyEnable') ?? 0;
        final server = key.getStringValue('ProxyServer')?.trim() ?? '';
        final pacUrl = key.getStringValue('AutoConfigURL')?.trim() ?? '';
        return SystemProxyConfig(
          proxyUrl: enabled != 0 && server.isNotEmpty
              ? parseProxyServer(server)
              : null,
          pacUrl: pacUrl.isEmpty ? null : pacUrl,
        );
      } finally {
        key.close();
      }
    } catch (e) {
      debugPrint('[SystemProxyDetector] 读取系统代理设置失败: $e');
      return const SystemProxyConfig();
    }
  }

  /// 把注册表 `ProxyServer` 值解析成代理 URL。
  ///
  /// 支持两种格式：
  /// - `host:port`（对所有协议生效）→ `http://host:port`
  /// - `http=h:p;https=h:p;socks=h:p`（按协议分列）→ 优先 https，其次
  ///   http，最后 socks（映射为 socks5，WinINet 的 socks= 即 SOCKS 代理）
  @visibleForTesting
  static String? parseProxyServer(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    if (!value.contains('=')) {
      return _normalize(value, 'http');
    }

    final entries = <String, String>{};
    for (final part in value.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final scheme = part.substring(0, idx).trim().toLowerCase();
      final host = part.substring(idx + 1).trim();
      if (host.isNotEmpty) entries[scheme] = host;
    }
    final https = entries['https'];
    if (https != null) return _normalize(https, 'http');
    final http = entries['http'];
    if (http != null) return _normalize(http, 'http');
    final socks = entries['socks'];
    if (socks != null) return _normalize(socks, 'socks5');
    return null;
  }

  static String? _normalize(String hostPort, String defaultScheme) {
    var v = hostPort.trim();
    if (v.isEmpty) return null;
    // 少数工具会把带 scheme 的地址直接写进注册表，做一次归一化。
    final schemeMatch = RegExp(r'^(https?|socks5?)://').firstMatch(v);
    String scheme = defaultScheme;
    if (schemeMatch != null) {
      scheme = schemeMatch.group(1) == 'socks' ? 'socks5' : schemeMatch.group(1)!;
      if (scheme == 'https') scheme = 'http';
      v = v.substring(schemeMatch.group(0)!.length);
    }
    // Uri 会把 http:80 / https:443 等默认端口归一化掉,不能用 hasPort 判定,
    // 这里显式要求 host:port 形式。
    final m = RegExp(r'^(\[[0-9a-fA-F:]+\]|[^:/\s]+):(\d{1,5})$').firstMatch(v);
    if (m == null) return null;
    final port = int.parse(m.group(2)!);
    if (port < 1 || port > 65535) return null;
    return '$scheme://${m.group(1)}:$port';
  }
}
