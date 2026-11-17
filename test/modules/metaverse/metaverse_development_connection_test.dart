import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/developer/session/development_connection.dart';

void main() {
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
