import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';

void main() {
  final bundlePath = Platform.environment['FLUXDO_PLUGIN_BUNDLE'];
  test('独立脚手架产物通过真实宿主清单与 RFW 校验', () {
    final bundle = jsonDecode(File(bundlePath!).readAsStringSync()) as Map;
    final manifest = MetaversePluginManifest.parse(bundle['manifest']);
    final files = bundle['files'] as Map;
    expect(manifest.apiVersion, 2);
    expect(manifest.runtimeSupported, isTrue);
    expect(manifest.networkHosts, isEmpty);
    expect(
      () => MetaversePluginInstaller.validateUi(
        manifest,
        files[manifest.uiPath] as String,
      ),
      returnsNormally,
    );
    expect(files[manifest.scriptPath], isNot(contains('import.meta.hot')));
  }, skip: bundlePath == null ? '设置 FLUXDO_PLUGIN_BUNDLE 验证工具发行产物' : false);
}
