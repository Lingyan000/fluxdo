@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/proxy_certificate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('代理初始化不会使普通 Dart HTTPS 信任随包 CA', () async {
    // 此用例需要真实 TLS，不使用 Flutter 测试绑定默认的 400 响应替身。
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    SharedPreferences.setMockInitialValues({'cert_use_per_device': false});
    final directory = await Directory.systemTemp.createTemp('fluxdo-trust-scope-');
    HttpServer? server;
    addTearDown(() async {
      binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', null);
      await server?.close(force: true);
      await directory.delete(recursive: true);
    });
    final generated = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
      '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
      '-addext', 'extendedKeyUsage=serverAuth', '-keyout', 'key.pem', '-out', 'ca.pem',
    ], workingDirectory: directory.path);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final cert = await File('${directory.path}/ca.pem').readAsBytes();
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (message) async {
      if (const StringCodec().decodeMessage(message) == 'assets/certs/proxy_ca.pem') {
        return ByteData.sublistView(cert);
      }
      return null;
    });
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(cert)
      ..usePrivateKey('${directory.path}/key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
    server.listen((request) async {
      request.response.write('local tls');
      await request.response.close();
    }, onError: (Object _) {});
    final uri = Uri.parse('https://127.0.0.1:${server.port}/');

    Future<void> request([SecurityContext? context]) async {
      final client = HttpClient(context: context)..connectionTimeout = const Duration(seconds: 3);
      try {
        final response = await (await client.getUrl(uri)).close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    }

    // 正向对照确认本地服务器证书可用，失败不能归因于监听或证书格式。
    await request(SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(cert));
    await expectLater(request(), throwsA(isA<HandshakeException>()));
    await ProxyCertificate.initialize();
    await expectLater(request(), throwsA(isA<HandshakeException>()));
  });
}
