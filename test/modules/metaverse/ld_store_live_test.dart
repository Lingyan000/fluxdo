import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/services/network/doh/doh_resolver.dart';
import 'package:fluxdo/services/network/core/net_core_bindings.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';
import 'package:fluxdo/services/network/proxy/proxy_settings_service.dart';

/// 显式开启时才访问士多公开接口，用真实套接字验证解析、SNI、TLS 和读取响应。
void main() {
  test('原生网络读取士多分类、商品和详情', () async {
    final manifest = MetaversePluginManifest.parse(
      jsonDecode(File('test/fixtures/metaverse/ld-store/plugin.json').readAsStringSync()),
    );
    const server = String.fromEnvironment('LD_STORE_TEST_DOH');
    final resolver = server.isEmpty
        ? null
        : DohResolver(serverUrl: server, enableFallback: false);
    if (resolver != null) addTearDown(resolver.dispose);
    const core = bool.fromEnvironment('LD_STORE_TEST_CORE');
    const proxyEnabled = bool.fromEnvironment('LD_STORE_TEST_PROXY');
    var tunnels = 0;
    MetaverseAddressLookup? lookup = resolver?.resolveAll;
    if (core) {
      ProxySettings? upstream;
      if (proxyEnabled) {
        // 仅允许本次士多 API 的域名及候选 IP，代理接收域名后自行选址。
        final ips =
            (await (resolver?.resolveAll('api2.ldspro.qzz.io') ??
                    InternetAddress.lookup('api2.ldspro.qzz.io')))
                .where((ip) => !MetaversePluginNetwork.isPrivateAddress(ip))
                .toList();
        lookup = (host) async {
          expect(host, 'api2.ldspro.qzz.io');
          return ips;
        };
        final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        addTearDown(() async {
          await proxy.close();
          for (final s in sockets) {
            s.destroy();
          }
        });
        proxy.listen((client) {
          sockets.add(client);
          final header = <int>[];
          late StreamSubscription<Uint8List> sub;
          sub = client.listen((chunk) async {
            header.addAll(chunk);
            if (header.length > 4096) {
              client.destroy();
              return;
            }
            final text = latin1.decode(header);
            if (!text.contains('\r\n\r\n')) return;
            sub.pause();
            final line = text.split('\r\n').first.split(' ');
            final uri = line.length == 3 && line.first == 'CONNECT'
                ? Uri.tryParse('https://${line[1]}')
                : null;
            final ip = uri == null ? null : InternetAddress.tryParse(uri.host);
            if (uri == null ||
                uri.port != 443 ||
                (uri.host != 'api2.ldspro.qzz.io' && !ips.contains(ip))) {
              client.destroy();
              return;
            }
            try {
              final remote = await Socket.connect(
                uri.host,
                443,
                timeout: const Duration(seconds: 4),
              );
              sockets.add(remote);
              tunnels++;
              client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
              await client.flush();
              sub.onData(remote.add);
              sub.onDone(remote.destroy);
              sub.onError((_) => remote.destroy());
              remote.listen(
                client.add,
                onDone: client.destroy,
                onError: (_) => client.destroy(),
              );
              sub.resume();
            } catch (_) {
              client.destroy();
            }
          }, onError: (_) => client.destroy());
        });
        upstream = ProxySettings(
          enabled: true,
          host: '127.0.0.1',
          port: proxy.port,
        );
      }
      expect(
        await NetCoreService.instance.start(
          NetCoreConfig(upstreamProxy: upstream),
        ),
        isTrue,
      );
      addTearDown(NetCoreService.instance.stop);
      expect(NetCoreBindings.instance.supportsPluginRequests, isTrue);
    }
    final client = MetaversePluginNetwork(
      lookup: lookup,
      useNetworkCore: () => core,
    );
    addTearDown(client.dispose);
    Future<Map<String, dynamic>> read(String path) async {
      final result = await client.fetch(
        manifest,
        request: {'url': 'https://api2.ldspro.qzz.io/api/shop/$path'},
        authToken: null,
      );
      expect(result['status'], 200, reason: path);
      final body = jsonDecode(result['body'] as String) as Map<String, dynamic>;
      expect(body['success'], true);
      return body['data'] as Map<String, dynamic>;
    }

    expect((await read('categories'))['categories'], isNotEmpty);
    final products = (await read('products?pageSize=2'))['products'] as List;
    expect(products, isNotEmpty);
    final id = products.first['id'].toString();
    expect(
      (await read(
        'products/${Uri.encodeComponent(id)}',
      ))['product']['id'].toString(),
      id,
    );
    if (proxyEnabled) expect(tunnels, greaterThan(0));
  }, skip: !const bool.fromEnvironment('LD_STORE_LIVE'));
}
