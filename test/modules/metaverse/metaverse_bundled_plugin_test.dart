import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('应用资源中的士多可以离线装入，无需另选插件文件', () async {
    final network = MetaversePluginNetwork();
    addTearDown(network.dispose);
    final installer = MetaversePluginInstaller(
      network: network,
      reservedHosts: ['linux.do'],
    );
    final packages = await installer.bundledPackages(rootBundle);
    final shop = packages.singleWhere(
      (package) => package.manifest.id == 'community.fluxdo.ldstore',
    );
    expect(shop.manifest.webLogin?.host, 'ldcstore.com');
    expect(shop.source, 'asset:plugins/ld-store/plugin.json');
    expect(shop.manifest.page('product')?.modal, true);
    expect(shop.manifest.auth.connect, isNotNull);
    expect(shop.manifest.auth.payment, 'linuxDoCredit');
    expect(shop.manifest.page('product')?.scroll, false);
    expect(shop.code.script, contains('fluxdo.auth.request()'));
    expect(shop.code.script, contains('fluxdo.checkout.pay('));
  });
}
