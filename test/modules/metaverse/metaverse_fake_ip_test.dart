import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_socket_connection.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _Socket implements Socket {
  var destroyed = false;
  @override
  void destroy() => destroyed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final manifest = MetaversePluginManifest.parse(
    jsonDecode(
      File('docs/examples/metaverse-plugin/plugin.json').readAsStringSync(),
    ),
  );
  final uri = Uri.parse('https://api.example.com/items');
  final cases = <String, List<String>>{
    'IPv4 Fake-IP': ['198.18.0.6'],
    '双栈 Fake-IP': ['2001:2::6', '198.18.0.6'],
    'IPv4 Fake-IP 与真实 IPv6': ['2606:4700::1111', '198.18.0.6'],
  };
  for (final entry in cases.entries) {
    for (final core in [false, true]) {
      test('${entry.key} 完整交给 ${core ? '核心' : 'IO'} 出口', () async {
        final adapter = _Adapter();
        var lookups = 0;
        final network = MetaversePluginNetwork(
          dio: Dio()..httpClientAdapter = adapter,
          coreDio: Dio()..httpClientAdapter = adapter,
          useNetworkCore: () => core,
          lookup: (_) async {
            lookups++;
            return entry.value.map(InternetAddress.new).toList();
          },
        );
        addTearDown(network.dispose);
        await network.fetch(
          manifest,
          request: {'url': '$uri'},
          authToken: null,
        );
        expect(lookups, 1);
        expect(adapter.requests.single.uri, uri);
        expect(adapter.requests.single.extra['pinnedAddresses'], entry.value);
      });
    }
  }

  test('Fake-IP 例外精确到指定范围，普通私网和 IP 字面量继续拒绝', () async {
    for (final ip in [
      '198.18.0.0',
      '198.19.255.255',
      '2001:2::',
      '2001:2:0:ffff::1',
      '::ffff:198.18.0.6',
    ]) {
      expect(
        MetaversePluginNetwork.isFakeIpAddress(InternetAddress(ip)),
        isTrue,
      );
      expect(
        MetaversePluginNetwork.isPrivateAddress(InternetAddress(ip)),
        isTrue,
      );
    }
    for (final ip in [
      '198.17.255.255',
      '198.20.0.0',
      '2001:2:1::',
      '10.0.0.1',
      'fd00::1',
    ]) {
      expect(
        MetaversePluginNetwork.isFakeIpAddress(InternetAddress(ip)),
        isFalse,
      );
    }
    final adapter = _Adapter();
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [
        InternetAddress('10.0.0.1'),
        InternetAddress('fd00::1'),
      ],
    );
    addTearDown(network.dispose);
    await expectLater(
      network.fetch(manifest, request: {'url': '$uri'}, authToken: null),
      throwsA(isA<MetaversePluginCallException>()),
    );
    for (final host in [
      '198.18.0.6',
      '[2001:2::6]',
      'router.local',
      'localhost',
    ]) {
      await expectLater(
        network.download(Uri.parse('https://$host/p'), maxBytes: 100),
        throwsA(isA<MetaversePluginCallException>()),
      );
    }
    expect(adapter.requests, isEmpty);
  });

  test('候选数量截断前交错地址族，保留排在大量 IPv6 后面的 IPv4', () async {
    final adapter = _Adapter();
    final network = MetaversePluginNetwork(
      dio: Dio()..httpClientAdapter = adapter,
      lookup: (_) async => [
        for (var i = 1; i <= 20; i++) InternetAddress('2001:2::$i'),
        InternetAddress('198.18.0.6'),
      ],
    );
    addTearDown(network.dispose);
    await network.fetch(manifest, request: {'url': '$uri'}, authToken: null);
    final candidates = adapter.requests.single.extra['pinnedAddresses'] as List;
    expect(candidates, hasLength(16));
    expect(candidates.take(2), ['2001:2::1', '198.18.0.6']);
  });

  test('本地 DNS 不可用时向核心保留原域名及空直连集合，供代理解析', () async {
    final adapter = _Adapter();
    final network = MetaversePluginNetwork(
      coreDio: Dio()..httpClientAdapter = adapter,
      useNetworkCore: () => true,
      lookup: (_) async => throw const SocketException('DNS unavailable'),
    );
    addTearDown(network.dispose);
    await network.fetch(manifest, request: {'url': '$uri'}, authToken: null);
    expect(adapter.requests.single.uri, uri);
    expect(adapter.requests.single.extra['pinnedAddresses'], isEmpty);
    await expectLater(
      network.fetch(
        manifest,
        request: {'url': 'https://unapproved.example.org/'},
        authToken: null,
      ),
      throwsA(isA<MetaversePluginCallException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  for (final entry in cases.entries) {
    test('${entry.key} 的 IPv6 不返回时，IPv4 完成 TLS 且取消旧连接', () async {
      final connected = _Socket();
      final attempts = <String>[];
      final cancelled = <String>[];
      final hosts = <String>[];
      final pending = Completer<Socket>();
      final task = await startMetaverseConnection(
        uri,
        entry.value.map(InternetAddress.new).toList(),
        attemptDelay: const Duration(milliseconds: 5),
        start: (address, port) async {
          expect(port, 443);
          attempts.add(address.address);
          return ConnectionTask.fromSocket(
            address.type == InternetAddressType.IPv6
                ? pending.future
                : Future.value(connected),
            () => cancelled.add(address.address),
          );
        },
        secure: (socket, host) async {
          hosts.add(host);
          return socket;
        },
      );
      expect(
        await task.socket.timeout(const Duration(seconds: 1)),
        same(connected),
      );
      expect(attempts, entry.value);
      expect(hosts, ['api.example.com']);
      expect(connected.destroyed, isFalse);
      if (entry.value.length > 1) {
        expect(cancelled, contains(entry.value.first));
        final lateSocket = _Socket();
        pending.complete(lateSocket);
        await Future<void>.delayed(Duration.zero);
        expect(lateSocket.destroyed, isTrue);
      }
    });
  }

  test('全部 TLS 校验失败时返回错误并关闭套接字', () async {
    final sockets = <_Socket>[];
    final task = await startMetaverseConnection(
      uri,
      ['198.18.0.6', '2001:2::6'].map(InternetAddress.new).toList(),
      attemptDelay: Duration.zero,
      start: (_, _) async {
        final socket = _Socket();
        sockets.add(socket);
        return ConnectionTask.fromSocket(Future.value(socket), () {});
      },
      secure: (_, host) async {
        expect(host, uri.host);
        throw const HandshakeException('certificate mismatch');
      },
    );
    await expectLater(task.socket, throwsA(isA<HandshakeException>()));
    expect(sockets, hasLength(2));
    expect(sockets.every((s) => s.destroyed), isTrue);
  });

  test('仅 IPv6 无响应时按期限失败并释放晚到的连接', () async {
    final pending = Completer<Socket>();
    var cancelled = false;
    final task = await startMetaverseConnection(
      uri,
      [InternetAddress('2001:2::6')],
      attemptTimeout: const Duration(milliseconds: 20),
      start: (_, _) async => ConnectionTask.fromSocket(pending.future, () {
        cancelled = true;
      }),
    );
    await expectLater(task.socket, throwsA(isA<TimeoutException>()));
    expect(cancelled, isTrue);
    final lateSocket = _Socket();
    pending.complete(lateSocket);
    await Future<void>.delayed(Duration.zero);
    expect(lateSocket.destroyed, isTrue);
  });

  test('取消会关闭在途连接并阻止后续候选启动', () async {
    final pending = Completer<Socket>();
    final started = Completer<void>();
    var attempts = 0;
    var cancelled = false;
    final task = await startMetaverseConnection(
      uri,
      ['2001:2::6', '198.18.0.6'].map(InternetAddress.new).toList(),
      start: (_, _) async {
        attempts++;
        started.complete();
        return ConnectionTask.fromSocket(pending.future, () {
          cancelled = true;
        });
      },
    );
    final failed = expectLater(task.socket, throwsA(isA<SocketException>()));
    await started.future;
    task.cancel();
    await failed;
    final lateSocket = _Socket();
    pending.complete(lateSocket);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(attempts, 1);
    expect(cancelled, isTrue);
    expect(lateSocket.destroyed, isTrue);
  });
}
