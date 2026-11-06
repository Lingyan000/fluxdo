// FLUXDO_LIVE=1，需本机核心与 openssl；所有 CA 只存在于临时目录，不安装到系统。
@TestOn('mac-os || linux')
library;

import 'dart:io' hide X509Certificate;
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/net_core_bindings.dart';
import 'package:fluxdo/services/network/core/net_core_service.dart';
import 'package:fluxdo/services/webview_settings.dart';

void main() {
  final skip = Platform.environment['FLUXDO_LIVE'] == '1'
      ? false
      : '需要本机核心与 openssl，设置 FLUXDO_LIVE=1';
  late Directory directory;
  late Uint8List validDer;
  late Uint8List otherDer;
  late NetCoreConfig config;

  Future<void> openssl(List<String> args) async {
    final result = await Process.run(
      'openssl',
      args,
      workingDirectory: directory.path,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  Future<Uint8List> issue(
    String prefix,
    ({String certPem, String keyPem}) ca,
  ) async {
    await File('${directory.path}/$prefix-ca.pem').writeAsString(ca.certPem);
    await File('${directory.path}/$prefix-ca.key').writeAsString(ca.keyPem);
    await openssl([
      'x509',
      '-req',
      '-in',
      'leaf.csr',
      '-CA',
      '$prefix-ca.pem',
      '-CAkey',
      '$prefix-ca.key',
      '-set_serial',
      '1',
      '-days',
      '1',
      '-extfile',
      'extensions.cnf',
      '-outform',
      'DER',
      '-out',
      '$prefix.der',
    ]);
    return File('${directory.path}/$prefix.der').readAsBytes();
  }

  Future<ServerTrustAuthResponse?> check({
    Uint8List? der,
    String host = 'image.example',
  }) => WebViewSettings.handleServerTrustAuthRequest(
    ServerTrustChallenge(
      protectionSpace: URLProtectionSpace(
        host: host,
        protocol: 'https',
        sslCertificate: SslCertificate(
          // 这个 CN 即使正确也不能替代 DER 验证。
          issuedBy: SslCertificateDName(CName: 'DOH Proxy CA'),
          x509Certificate: der == null
              ? null
              : X509Certificate.fromDerData(der: der),
        ),
      ),
    ),
  );

  setUpAll(() async {
    if (skip != false) return;
    directory = await Directory.systemTemp.createTemp('fluxdo-webview-trust-');
    final ca = NetCoreService.instance.generateCa()!;
    final otherCa = NetCoreService.instance.generateCa()!;
    await openssl([
      'req',
      '-new',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=image.example',
      '-keyout',
      'leaf.key',
      '-out',
      'leaf.csr',
    ]);
    await File('${directory.path}/extensions.cnf').writeAsString(
      'basicConstraints=critical,CA:FALSE\n'
      'keyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n'
      'subjectAltName=DNS:image.example\n',
    );
    validDer = await issue('current', ca);
    otherDer = await issue('other', otherCa);
    config = NetCoreConfig(
      webViewMitm: true,
      caCertPem: ca.certPem,
      caKeyPem: ca.keyPem,
    );
  });
  setUp(() async {
    if (skip == false) {
      expect(await NetCoreService.instance.start(config), isTrue);
    }
  });
  tearDownAll(() async {
    if (skip != false) return;
    await NetCoreService.instance.stop();
    await directory.delete(recursive: true);
  });

  test('当前核心 CA 签发且主机匹配才允许额外信任', () async {
    expect(
      (await check(der: validDer))?.action,
      ServerTrustAuthResponseAction.PROCEED,
    );
    expect(await check(der: validDer, host: 'wrong.example'), isNull);
    expect(await check(der: otherDer), isNull);
  }, skip: skip);
  test('同名 issuer 但缺少证书数据时保留平台默认校验', () async {
    expect(await check(), isNull);
    expect(
      NetCoreBindings.instance.verifyWebViewCertificate([], 'image.example'),
      isFalse,
    );
    expect(
      NetCoreBindings.instance.verifyWebViewCertificate([
        1,
        2,
        3,
      ], 'image.example'),
      isFalse,
    );
  }, skip: skip);
  test('关闭 MITM 或核心后不再额外信任先前证书', () async {
    expect(await NetCoreService.instance.start(const NetCoreConfig()), isTrue);
    expect(await check(der: validDer), isNull);
    expect(
      NetCoreBindings.instance.verifyWebViewCertificate(
        validDer,
        'image.example',
      ),
      isFalse,
    );
    await NetCoreService.instance.stop();
    expect(
      NetCoreBindings.instance.verifyWebViewCertificate(
        validDer,
        'image.example',
      ),
      isFalse,
    );
  }, skip: skip);
}
