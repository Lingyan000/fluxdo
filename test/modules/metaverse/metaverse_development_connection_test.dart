import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/developer/session/development_connection.dart';

void main() {
  test('局域网地址必须有指纹，重复参数、公网地址与降级连接被拒绝', () {
    final key = 'k' * 32, cert = 'a' * 64;
    expect(DevelopmentConnection.parse('fluxdo-dev://192.168.1.12:5174?key=$key&cert=$cert').host, '192.168.1.12');
    for (final uri in [
      'fluxdo-dev://192.168.1.12:5174?key=$key',
      'fluxdo-dev://8.8.8.8:5174?key=$key&cert=$cert',
      'fluxdo-dev://127.0.0.1:5174?key=$key&key=$key',
      'fluxdo-dev://127.0.0.1:5174?key=$key&cert=invalid',
    ]) {
      expect(() => DevelopmentConnection.parse(uri), throwsFormatException);
    }
  });

  test('真实 TLS 配对校验指纹，在证书拒绝前不发送令牌', () async {
    // 仅用于回归的公开测试证书，不用于发布或真实配对。
    final security = SecurityContext()
      ..useCertificateChain('test/fixtures/metaverse/dev-test-cert.pem')
      ..usePrivateKey('test/fixtures/metaverse/dev-test-key.pem');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, security);
    final cert = File('test/fixtures/metaverse/dev-test-cert.pem').readAsStringSync()
        .replaceAll(RegExp(r'-----[^-]+-----|\s'), '');
    final fingerprint = sha256.convert(base64Decode(cert)).toString();
    final requests = <HttpRequest>[], peers = <WebSocket>[];
    server.listen((request) async {
      requests.add(request);
      final ws = await WebSocketTransformer.upgrade(request);
      peers.add(ws);
      ws.add('{"type":"secure"}');
    }, onError: (Object _) {});
    final messages = <Map<String, dynamic>>[];
    final connection = DevelopmentConnection(onMessage: messages.add, onDisconnected: () {});
    addTearDown(() async {
      connection.close();
      for (final peer in peers) { await peer.close(); }
      await server.close(force: true);
    });
    final pairing = 'fluxdo-dev://127.0.0.1:${server.port}?key=${'k' * 32}&cert=';
    await expectLater(connection.connect('$pairing${'0' * 64}'), throwsA(isA<HandshakeException>()));
    expect(requests, isEmpty);
    await connection.connect('$pairing$fingerprint');
    await _until(() => messages.isNotEmpty);
    expect(requests.single.headers.value('authorization'), 'Bearer ${'k' * 32}');
    expect(requests.single.uri.query, isEmpty);
  });
  test('WebSocket 断连可重建且使用 header 配对，关闭不触发恢复', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <HttpRequest>[];
    final peers = <WebSocket>[];
    server.listen((request) async {
      requests.add(request);
      final ws = await WebSocketTransformer.upgrade(request);
      peers.add(ws);
      ws.add(jsonEncode({'type': 'test', 'value': peers.length}));
    });
    final messages = <Map<String, dynamic>>[];
    var disconnects = 0;
    final connection = DevelopmentConnection(
      onMessage: messages.add,
      onDisconnected: () => disconnects++,
    );
    addTearDown(() async {
      connection.close();
      for (final peer in peers) {
        await peer.close();
      }
      await server.close(force: true);
    });
    final pairing = 'fluxdo-dev://127.0.0.1:${server.port}?key=${'x' * 32}';
    await connection.connect(pairing);
    await _until(() => messages.length == 1);
    expect(requests.single.uri.query, isEmpty);
    expect(
      requests.single.headers.value('authorization'),
      'Bearer ${'x' * 32}',
    );
    await peers.single.close();
    await _until(() => disconnects == 1);
    await connection.connect(pairing);
    await _until(() => messages.length == 2);
    connection.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(disconnects, 1);
  });
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待开发会话超时');
}
