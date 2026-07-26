import 'package:flutter/foundation.dart';

import 'proxy_settings_service.dart';

/// 本地 DoH/WebView 网关使用的最终上游代理。
///
/// 优先级固定为：应用内代理 > Windows 固定系统代理 > 直连。
@immutable
class GatewayUpstream {
  const GatewayUpstream({
    required this.protocol,
    required this.host,
    required this.port,
    this.username,
    this.password,
    this.cipher,
  });

  final String protocol;
  final String host;
  final int port;
  final String? username;
  final String? password;
  final String? cipher;

  static GatewayUpstream? resolve({
    required ProxySettings applicationProxy,
    required String? systemProxyUrl,
  }) {
    if (applicationProxy.isValid) {
      return GatewayUpstream(
        protocol: applicationProxy.protocol.storageValue,
        host: applicationProxy.host,
        port: applicationProxy.port,
        username: applicationProxy.username,
        password: applicationProxy.password,
        cipher: applicationProxy.cipher,
      );
    }
    return fromSystemProxyUrl(systemProxyUrl);
  }

  @visibleForTesting
  static GatewayUpstream? fromSystemProxyUrl(String? proxyUrl) {
    final uri = proxyUrl == null ? null : Uri.tryParse(proxyUrl);
    if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
    final protocol = switch (uri.scheme.toLowerCase()) {
      'socks' || 'socks5' => UpstreamProxyProtocol.socks5.storageValue,
      'http' || 'https' => UpstreamProxyProtocol.http.storageValue,
      _ => null,
    };
    if (protocol == null) return null;
    return GatewayUpstream(protocol: protocol, host: uri.host, port: uri.port);
  }
}
