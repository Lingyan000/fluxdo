import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// 回环连接可由桌面直接访问，Android 通过 adb reverse 转发；
/// 局域网连接必须携带临时证书指纹，凭证只在验证 TLS 后发送。
/// 不依赖插件的网络能力，不把开发端口或配对令牌传给插件。
class DevelopmentConnection {
  DevelopmentConnection({
    required this.onMessage,
    required this.onDisconnected,
  });
  final void Function(Map<String, dynamic>) onMessage;
  final void Function() onDisconnected;
  WebSocket? _socket;
  HttpClient? _client;
  int _generation = 0;
  bool get connected => _socket?.readyState == WebSocket.open;

  static Uri parse(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'fluxdo-dev' ||
        !_localAddress(uri.host) ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.queryParametersAll.values.any((values) => values.length != 1) ||
        uri.queryParameters.keys.any((key) => key != 'key' && key != 'cert') ||
        (uri.queryParameters.containsKey('cert') &&
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.queryParameters['cert']!)) ||
        (uri.host != '127.0.0.1' && !uri.queryParameters.containsKey('cert')) ||
        !RegExp(r'^[A-Za-z0-9_-]{32}$')
            .hasMatch(uri.queryParameters['key'] ?? '')) {
      throw const FormatException('development_invalid_pairing');
    }
    return uri;
  }

  static bool _localAddress(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null || address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return host == '127.0.0.1' || bytes[0] == 10 ||
        bytes[0] == 192 && bytes[1] == 168 ||
        bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31;
  }

  Future<void> connect(String pairing) async {
    final uri = parse(pairing);
    close();
    final generation = _generation;
    final fingerprint = uri.queryParameters['cert'];
    // 独立信任库只接受当前配对证书，避免受信任的其他证书绕过指纹检查。
    final client = HttpClient(context: fingerprint == null ? null : SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 5);
    if (fingerprint != null) {
      client.badCertificateCallback = (certificate, host, port) =>
          host == uri.host && port == uri.port &&
          sha256.convert(certificate.der).toString() == fingerprint;
    }
    client.findProxy = (_) => 'DIRECT';
    _client = client;
    late final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        '${fingerprint == null ? 'ws' : 'wss'}://${uri.host}:${uri.port}/fluxdo',
        headers: {'Authorization': 'Bearer ${uri.queryParameters['key']}'},
        customClient: client,
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
    if (generation != _generation) {
      await socket.close();
      return;
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 15);
    socket.listen(
      (packet) {
        try {
          if (packet is! String ||
              utf8.encode(packet).length > 2 * 1024 * 1024) {
            throw const FormatException('development_packet_size');
          }
          final message = jsonDecode(packet);
          if (message is! Map<String, dynamic>) {
            throw const FormatException('development_packet_invalid');
          }
          onMessage(message);
        } catch (_) {
          socket.close(WebSocketStatus.policyViolation);
        }
      },
      onError: (Object _) {},
      onDone: () {
        if (generation != _generation) {
          return;
        }
        _socket = null;
        client.close(force: true);
        onDisconnected();
      },
    );
  }

  void send(Map<String, dynamic> message) {
    if (connected) {
      _socket!.add(jsonEncode(message));
    }
  }

  void close() {
    _generation++;
    unawaited(_socket?.close());
    _socket = null;
    _client?.close(force: true);
    _client = null;
  }
}
