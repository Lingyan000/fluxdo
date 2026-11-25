import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_package_signature.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';

void main() {
  test('实际发行插件包通过原生签名和安装结构校验',() async {
    final network=MetaversePluginNetwork();addTearDown(network.dispose);
    for(final name in ['ld-store-2.8.0','activity-feed-1.4.0']) {
      final result=await MetaversePluginInstaller(network:network).importBundle(File('test/fixtures/metaverse/$name.fluxplugin').openRead());
      expect(result.signature,isNotNull);
      expect(result.manifest.requiredFeatures,contains('storageScopes'));
    }
  });
  final fixtures = jsonDecode(
    File('test/fixtures/metaverse/sdk/signatures.json').readAsStringSync(),
  ) as Map;
  Map<String, dynamic> fixture(String name) =>
      (jsonDecode(jsonEncode(fixtures[name])) as Map).cast<String, dynamic>();
  test('Node 签名由原生宿主验证，轮换须由旧公钥确认', () async {
    final signed = fixture('signed'), rotated = fixture('rotated');
    final original = MetaversePackageSignature.verify(signed)!;
    final next = MetaversePackageSignature.verify(rotated)!;
    expect(next.fingerprint, isNot(original.fingerprint));
    expect(next.previousFingerprint, original.fingerprint);
    final network = MetaversePluginNetwork();
    addTearDown(network.dispose);
    final result = await MetaversePluginInstaller(network: network)
        .importBundle(Stream.value(utf8.encode(jsonEncode(signed))));
    expect(result.signature!.fingerprint, original.fingerprint);
    expect(
      MetaversePackageSignature.verify(signed..remove('publisher')),
      isNull,
    );
  });
  test('清单、脚本、界面和密钥轮换证明的篡改均被拒绝', () {
    for (final modify in <void Function(Map)>[
      (b) => b['manifest']['name'] = 'changed',
      (b) => b['files']['main.js'] += '//changed',
      (b) => b['files']['ui.rfwtxt'] += ' ',
      (b) =>
          b['publisher']['rotation']['signature'] = b['publisher']['signature'],
    ]) {
      final bundle = fixture('rotated');
      modify(bundle);
      expect(() => MetaversePackageSignature.verify(bundle), throwsA(anything));
    }
  });
}
