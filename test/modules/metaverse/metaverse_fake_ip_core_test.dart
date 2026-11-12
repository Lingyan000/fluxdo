// FLUXDO_LIVE=1 flutter test test/modules/metaverse/metaverse_fake_ip_core_test.dart
// 使用本机核心和仅监听回环的代理，验证真实 FFI，不访问外网。
@TestOn('mac-os || linux || windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/metaverse_plugin_runtime.dart';
import 'package:fluxdo/services/network/core/net_core_bindings.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

void main() {
  test('插件真实 FFI 向配置的代理传域名，支持 Fake-IP 和本地 DNS 失败', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final requests = <String>[];
    proxy.listen((socket) {
      sockets.add(socket);
      var header = '';
      var replied = false;
      socket.listen((data) {
        if (replied) return;
        header += latin1.decode(data);
        if (!header.contains('\r\n\r\n')) return;
        replied = true;
        requests.add(header.split('\r\n').first);
        // 观察 CONNECT 后结束请求，全程不向目标域名转发。
        socket.write('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n');
        unawaited(
          socket.flush().then<void>(
            (_) => socket.destroy(),
            onError: (_) => socket.destroy(),
          ),
        );
      }, onError: (_) => socket.destroy());
    });
    addTearDown(() async {
      await NetCoreService.instance.stop();
      await proxy.close();
      for (final socket in sockets) {
        socket.destroy();
      }
    });
    expect(
      await NetCoreService.instance.start(
        NetCoreConfig(
          upstreamProxy: ProxySettings(
            enabled: true,
            host: '127.0.0.1',
            port: proxy.port,
          ),
        ),
      ),
      isTrue,
    );
    expect(NetCoreBindings.instance.supportsPluginRequests, isTrue);
    final manifest = MetaversePluginManifest.parse(
      jsonDecode(
        File('docs/examples/metaverse-plugin/plugin.json').readAsStringSync(),
      ),
    );
    for (final addresses in [
      ['198.18.0.6'],
      ['2001:2::6', '198.18.0.6'],
      ['198.18.0.6', '2606:4700::1111'],
      <String>[],
    ]) {
      final count = requests.length;
      final network = MetaversePluginNetwork(
        useNetworkCore: () => true,
        lookup: (_) async {
          if (addresses.isEmpty) throw const SocketException('DNS unavailable');
          return addresses.map(InternetAddress.new).toList();
        },
      );
      try {
        await expectLater(
          network.fetch(
            manifest,
            request: {'url': 'https://api.example.com/items'},
            authToken: null,
          ),
          throwsA(isA<MetaversePluginCallException>()),
        );
        expect(requests, hasLength(count + 1));
        expect(requests.last, 'CONNECT api.example.com:443 HTTP/1.1');
      } finally {
        network.dispose();
      }
    }
  }, skip: Platform.environment['FLUXDO_LIVE'] != '1');
}
