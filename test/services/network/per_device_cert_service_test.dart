import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/per_device_cert_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late int generated;

  PerDeviceCertService service({Future<Directory> Function()? resolver}) =>
      PerDeviceCertService.forTesting(
        certsDirectory: resolver ?? () async => directory,
        generateCa: () {
          generated++;
          return (certPem: 'cert-$generated', keyPem: 'key-$generated');
        },
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluxdo-ca-store-');
    generated = 0;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async => directory.delete(recursive: true));

  test('并发加载只生成一对材料，重新加载保持证书身份', () async {
    final store = service();
    expect(await Future.wait(List.generate(20, (_) => store.ensureCaCert())), everyElement(true));
    expect(generated, 1);
    final next = service();
    expect(await next.ensureCaCert(), true);
    expect(next.certPem, store.certPem);
    expect(next.keyPem, store.keyPem);
    expect(generated, 1);
    final persisted = jsonDecode(await File('${directory.path}/ca.json').readAsString());
    expect(persisted['certPem'], 'cert-1');
    expect(persisted['keyPem'], 'key-1');
  });

  test('旧格式迁移不更换已安装 CA', () async {
    await File('${directory.path}/ca.crt').writeAsString('installed-cert');
    await File('${directory.path}/ca.key').writeAsString('installed-key');
    final store = service();
    expect(await store.ensureCaCert(), true);
    expect(store.certPem, 'installed-cert');
    expect(store.keyPem, 'installed-key');
    expect(generated, 0);
    expect(await File('${directory.path}/ca.json').exists(), true);
    expect(await File('${directory.path}/ca.key').exists(), false);
  });

  test('旧材料不完整或新格式损坏时不静默替换信任锚点', () async {
    await File('${directory.path}/ca.crt').writeAsString('installed-cert');
    expect(await service().ensureCaCert(), false);
    await File('${directory.path}/ca.key').writeAsString('installed-key');
    await File('${directory.path}/ca.json').writeAsString('{broken');
    expect(await service().ensureCaCert(), false);
    expect(generated, 0);
    expect(await File('${directory.path}/ca.crt').readAsString(), 'installed-cert');
  });

  test('加载中重置按序执行且清除已安装标记', () async {
    final gate = Completer<void>();
    final store = service(resolver: () async { await gate.future; return directory; });
    await store.markCertInstalled();
    final loading = store.ensureCaCert();
    final resetting = store.reset();
    gate.complete();
    expect(await loading, true);
    await resetting;
    expect(store.isLoaded, false);
    expect(store.certPem, isNull);
    expect(await store.isCertInstalled(), false);
    expect(await File('${directory.path}/ca.json').exists(), false);
    expect(await store.ensureCaCert(), true);
    expect(generated, 2);
  });

  test('保存失败不会发布内存状态或阻塞后续重试', () async {
    final blocker = Directory('${directory.path}/ca.json.tmp');
    await blocker.create();
    final store = service();
    await expectLater(store.ensureCaCert(), throwsA(isA<FileSystemException>()));
    expect(store.isLoaded, false);
    expect(store.certPem, isNull);
    await blocker.delete();
    expect(await store.ensureCaCert(), true);
    expect(store.certPem, 'cert-2');
    expect(store.keyPem, 'key-2');
  });
}
