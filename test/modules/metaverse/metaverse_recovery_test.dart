import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_backup.dart';
import 'package:fluxdo/modules/metaverse/market/metaverse_update_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_store.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_manifest.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_installer.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_approval_change.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_data_migration.dart';
import 'package:fluxdo/modules/metaverse/plugin/providers/metaverse_plugin_providers.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/secret_store_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/services/data_management/data_backup_service.dart';

import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_network.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_credential.dart';
import 'package:fluxdo/modules/metaverse/plugin/metaverse_plugin_permission.dart';

import 'metaverse_auto_update_test.dart' show updatePackage, updateManifest;

class _NoAccount extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ProviderContainer container;
  late MetaversePluginStore store;
  late MetaversePluginsController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-recovery-');
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(_NoAccount.new),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        metaversePluginDirectoryProvider.overrideWith((ref) async => directory),
      ],
    );
    controller = container.read(metaversePluginsProvider.notifier);
    store = container.read(metaversePluginStoreProvider);
    await controller.install(updatePackage('1.0.0'));
    await controller.setEnabled('example.updates', enabled: true);
    await store.updateStorage('example.updates', 'list', ['alice']);
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  test('索引提交前中断丢弃候选，提交后中断恢复同版本数据', () async {
    final previous = controller.byId('example.updates')!;
    final package = updatePackage('1.1.0');
    await store.writeCode(previous.id, package.code);
    final next = InstalledMetaversePlugin(
      manifest: package.manifest,
      source: previous.source,
      codeRevision: MetaversePluginStore.revisionOf(package.code),
    );
    await store.prepareRelease(previous, next, {
      'list': ['bob'],
    });
    await store.settleRelease(previous);
    expect(await store.readStorage(previous.id), {
      'list': ['alice'],
    });
    await store.prepareRelease(previous, next, {
      'list': ['bob'],
    });
    await store.saveIndex([next]);
    await store.settleRelease(store.loadIndex().single);
    expect(await store.readStorage(previous.id), {
      'list': ['bob'],
    });
    await store.settleRelease(next);
    expect((await store.previousRelease(next))!.manifest.version, '1.0.0');
  });

  test('回退恢复数据并阻断同一故障包，重置后不能恢复旧数据', () async {
    await controller.install(updatePackage('1.1.0'));
    await store.updateStorage('example.updates', 'list', ['changed']);
    await controller.rollback('example.updates', automatic: true);
    final old = controller.byId('example.updates')!;
    expect(old.manifest.version, '1.0.0');
    expect(old.enabled, false);
    expect(await store.readStorage(old.id), {
      'list': ['alice'],
    });
    await expectLater(
      controller.installAutomatic(updatePackage('1.1.0'), old, () => true),
      throwsA(anything),
    );
    await controller.resetData(old.id);
    expect(await store.releaseStatus(old.id), isEmpty);
  });

  test('新增后台任务按唯一凭证账号迁移旧数据，回退恢复原分区', () async {
    final raw=updateManifest('1.1.0');
    raw['permissions']={'network':['api.example.org'],'credentials':{'account':{'requests':[{'origin':'https://api.example.org','pathPrefix':'/api','methods':['GET']}]}}};
    final source=controller.byId('example.updates')!.source;
    final code=updatePackage('1.1.0').code;
    await controller.install(MetaversePluginPackage(manifest:MetaversePluginManifest.parse(raw),source:source,code:code));
    await store.writeCredential('example.updates','account',const MetaverseCredential('fixture',accountId:42),
      revision:store.credentialRevision('example.updates','account'),isActive:()=>true);
    await controller.install(MetaversePluginPackage(manifest:MetaversePluginManifest.parse({...raw,'version':'1.2.0',
      'requiredFeatures':['scheduledTasks'],'tasks':[{'id':'refresh','title':'刷新'}]}),source:source,code:code));
    expect(await store.readStorage('example.updates'),{'@forum-account:42:list':['alice']});
    await controller.rollback('example.updates',reviewed:true);
    expect(await store.readStorage('example.updates'),{'list':['alice']});
  });

  test('仅保留当前和上一版本代码，运行成功后仍可显式回退', () async {
    await controller.install(updatePackage('1.1.0'));
    await controller.install(updatePackage('1.2.0'));
    final current = controller.byId('example.updates')!;
    await store.markHealthy(current.id, current.codeRevision);
    expect(await store.previousRelease(current, probationOnly: true), isNull);
    expect((await store.previousRelease(current))!.manifest.version, '1.1.0');
    expect(
      Directory('${directory.path}/${current.id}')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('code-'))
          .length,
      2,
    );
  });

  test('备份不含代码或凭证，暂存恢复不改变安装索引，旧索引不再普通导入', () async {
    await controller.setPermission('example.updates', MetaversePluginPermission.identity, true);
    final backup = MetaversePluginBackup(directory);
    final section = await backup.export(store);
    expect(jsonEncode(section), isNot(contains('codeRevision')));
    expect(jsonEncode(section), isNot(contains('main.js":"')));
    backup.stage(section);
    expect(backup.pending().single['data'], {
      'list': ['alice'],
    });
    expect(controller.byId('example.updates')!.enabled, true);
    expect(
      DataBackupService.debugShouldBackup(MetaversePluginStore.indexKey),
      false,
    );
    final record = backup.pending().single;
    await controller.restoreBackup(updatePackage('1.1.0'), record, {});
    expect(controller.byId('example.updates')!.enabled, false);
    expect(controller.byId('example.updates')!.allows(MetaversePluginPermission.identity), false);
    expect(backup.pending(), isEmpty);
    expect(await store.readStorage('example.updates'), record['data']);
    expect(
      () => backup.stage({
        'version': 1,
        'plugins': [record, record],
      }),
      throwsFormatException,
    );
  });

  test('恢复队列满时保持原有更新计划，成功暂存后才恢复设置', () {
    final backup = MetaversePluginBackup(directory);
    final updates = MetaverseUpdateStore(directory);
    Map<String, dynamic> record(int index) => {
      'manifest': {...updateManifest('1.0.0'), 'id': 'example.restore$index'},
      'source': 'file:example.restore$index',
      'data': <String, dynamic>{},
    };
    backup.stage({
      'version': 1,
      'plugins': [for (var i = 0; i < 32; i++) record(i)],
    });
    final section = {
      'version': 1,
      'plugins': [record(32)],
      'updates': {'frequency': 'sixHours', 'preview': true},
    };
    expect(() => backup.stage(section), throwsFormatException);
    expect(backup.pending(), hasLength(32));
    expect(updates.snapshot().frequency, MetaverseUpdateFrequency.daily);
    expect(updates.snapshot().preview, false);
    backup.remove('example.restore0');
    backup.stage(section);
    expect(backup.pending(), hasLength(32));
    expect(updates.snapshot().frequency, MetaverseUpdateFrequency.sixHours);
    expect(updates.snapshot().preview, true);
  });

  test('权限减少可自动更新，扩大域名及凭证路径须审阅', () {
    final broad = updateManifest('1.0.0');
    broad['permissions'] = {
      'network': ['*.example.org'],
      'identity': true,
      'credentials': {
        'account': {
          'requests': [
            {
              'origin': 'https://api.example.org',
              'pathPrefix': '/api',
              'methods': ['GET', 'POST'],
            },
          ],
        },
      },
    };
    final narrow = jsonDecode(jsonEncode(broad)) as Map<String, dynamic>;
    narrow['permissions']['network'] = ['api.example.org'];
    narrow['permissions']['identity'] = false;
    narrow['permissions']['credentials']['account']['requests'][0]['pathPrefix'] =
        '/api/items';
    narrow['permissions']['credentials']['account']['requests'][0]['methods'] =
        ['GET'];
    final a = MetaversePluginManifest.parse(broad),
        b = MetaversePluginManifest.parse(narrow);
    expect(b.canUpdateWithoutApproval(a), true);
    expect(a.canUpdateWithoutApproval(b), false);
    expect(a.expandedApprovalFrom(b), contains('credentials.account'));
  });

  test('真实 QuickJS 迁移逐账号处理，失败保留原数据且拒绝联网', () async {
    final raw = updateManifest('2.0.0')
      ..['dataVersion'] = 2
      ..['requiredFeatures'] = ['dataMigrations'];
    MetaversePluginPackage package(String script) => MetaversePluginPackage(
      manifest: MetaversePluginManifest.parse(raw),
      source: 'file:example.updates',
      code: (ui: updatePackage('1.0.0').code.ui, script: script),
    );
    final data = <String, Object?>{
      '@forum-account:1:list': ['alice'],
      '@forum-account:2:list': ['bob'],
    };
    final migrated = await migrateMetaverseData(
      package: package(
        'fluxdo.on("storage.migrate",async(ctx,args)=>{const list=await ctx.api.storage.get("list");await ctx.api.storage.setMany({list:null,people:list,version:args.toVersion});});',
      ),
      fromVersion: 1,
      data: data,
      engineFactory: createMetaverseScriptEngine,
    );
    expect(migrated, {
      '@forum-account:1:people': ['alice'],
      '@forum-account:1:version': 2,
      '@forum-account:2:people': ['bob'],
      '@forum-account:2:version': 2,
    });
    await expectLater(
      migrateMetaverseData(
        package: package(
          'fluxdo.on("storage.migrate",async(ctx)=>{await ctx.api.storage.set("list",[]);await ctx.api.fetch("https://api.example.org");});',
        ),
        fromVersion: 1,
        data: data,
        engineFactory: createMetaverseScriptEngine,
      ),
      throwsA(anything),
    );
    expect(data['@forum-account:1:list'], ['alice']);
  });
  test('同版本恢复按安装批次识别提交结果，新设备恢复清空历史并保持停用', () async {
    final old = controller.byId('example.updates')!;
    InstalledMetaversePlugin candidate() => InstalledMetaversePlugin(
      manifest: old.manifest,
      source: old.source,
      codeRevision: old.codeRevision,
      installationId: InstalledMetaversePlugin.newInstallationId(),
    );
    var next = candidate();
    await store.prepareRelease(old, next, {'restored': true}, reset: true);
    await store.settleRelease(old);
    expect(await store.readStorage(old.id), {
      'list': ['alice'],
    });
    next = candidate();
    await store.prepareRelease(old, next, {'restored': true}, reset: true);
    await store.saveIndex([next]);
    await store.settleRelease(next);
    expect(await store.readStorage(old.id), {'restored': true});
    expect(await store.releaseStatus(old.id), isEmpty);
    final backup = MetaversePluginBackup(directory);
    final record = backup.validate({
      'version': 1,
      'plugins': [
        {
          'manifest': old.manifest.raw,
          'source': old.source,
          'data': {'fresh': 1},
        },
      ],
    }).single;
    await controller.remove(old.id);
    await controller.restoreBackup(updatePackage('1.0.0'), record, {});
    expect(controller.byId(old.id)!.enabled, false);
    expect(await store.readStorage(old.id), {'fresh': 1});
  });

  test('自动回退不能扩大基础域名权限，手动审阅后才回退', () async {
    await controller.install(updatePackage('1.1.0', expanded: true));
    await controller.install(updatePackage('1.2.0'));
    await controller.rollback('example.updates', automatic: true);
    expect(controller.byId('example.updates')!.manifest.version, '1.2.0');
    expect(
      controller.byId('example.updates')!.suspendedReason,
      'rollback_review_required',
    );
    await expectLater(controller.resume('example.updates'), throwsA(anything));
    await controller.rollback('example.updates', reviewed: true);
    expect(controller.byId('example.updates')!.manifest.version, '1.1.0');
    expect(controller.byId('example.updates')!.enabled, false);
  });

  test('真实引擎启动失败恢复上一版本数据，成功首屏标记健康', () async {
    await controller.install(updatePackage('1.1.0'));
    final hosts = container.read(metaversePluginHostsProvider);
    final healthy = controller.byId('example.updates')!;
    await hosts.hostFor(healthy).open(kind: 'page', page: 'home');
    for (
      var n = 0;
      n < 100 && (await store.releaseStatus(healthy.id))['healthy'] != true;
      n++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((await store.releaseStatus(healthy.id))['healthy'], true);
    final next = updatePackage('1.2.0');
    await controller.install(
      MetaversePluginPackage(
        manifest: next.manifest,
        source: next.source,
        code: (ui: next.code.ui, script: 'throw new Error("startup failed");'),
      ),
    );
    await expectLater(
      hosts
          .hostFor(controller.byId(healthy.id)!)
          .open(kind: 'page', page: 'home'),
      throwsA(anything),
    );
    for (
      var n = 0;
      n < 100 && controller.byId(healthy.id)!.manifest.version != '1.1.0';
      n++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await controller.reloadHost(healthy.id);
    expect(controller.byId(healthy.id)!.manifest.version, '1.1.0');
    expect(controller.byId(healthy.id)!.enabled, false);
  });

  test('旧备份仅转入待恢复队列，非法偏好和来源不能执行', () {
    final backup = MetaversePluginBackup(directory);
    final old = controller.byId('example.updates')!;
    final section = backup.sectionFrom({
      'data': {
        MetaversePluginStore.indexKey: {
          'value': jsonEncode([old.toJson()]),
        },
      },
    });
    final restored = backup.validate(section).single;
    expect(restored['data'], isEmpty);
    expect(restored.containsKey('enabled'), false);
    expect(
      () => backup.validate({
        'version': 1,
        'plugins': [
          {...restored, 'source': 'file:../../else'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('范围缩减保留仍有效凭证，已关闭权限不重新授权', () async {
    final raw = updateManifest('1.1.0');
    raw['permissions'] = {
      'network': ['api.example.org'],
      'credentials': {
        'account': {
          'requests': [
            {
              'origin': 'https://api.example.org',
              'pathPrefix': '/api',
              'methods': ['GET', 'POST'],
            },
          ],
        },
      },
    };
    MetaversePluginPackage pack() => MetaversePluginPackage(
      manifest: MetaversePluginManifest.parse(raw),
      source: updatePackage('1.0.0').source,
      code: updatePackage(raw['version'] as String).code,
    );
    await controller.install(
      pack(),
      choices: {MetaversePluginPermission.serviceAccount: true},
    );
    await store.writeCredential(
      'example.updates',
      'account',
      MetaverseCredential.parse({'secret': 'test-only', 'accountId': null})!,
      revision: store.credentialRevision('example.updates', 'account'),
      isActive: () => true,
    );
    raw['version'] = '1.2.0';
    raw['permissions']['credentials']['account']['requests'][0]['methods'] = [
      'GET',
    ];
    expect(
      await controller.installAutomatic(
        pack(),
        controller.byId('example.updates')!,
        () => true,
      ),
      true,
    );
    expect(await store.readCredential('example.updates', 'account'), isNotNull);
  });

  test('签名连续性允许密钥轮换，不能自动降为无签名或换发布者', () async {
    final network = MetaversePluginNetwork();
    addTearDown(network.dispose);
    final installer = MetaversePluginInstaller(network: network);
    final fixtures = jsonDecode(
      File('test/fixtures/metaverse/sdk/signatures.json').readAsStringSync(),
    ) as Map;
    Future<MetaversePluginPackage> read(Object bundle) =>
        installer.importBundle(Stream.value(utf8.encode(jsonEncode(bundle))));
    final signed = await read(fixtures['signed']);
    await controller.install(signed);
    final previous = controller.byId(signed.manifest.id)!;
    final rotated = await read(fixtures['rotated']);
    final untrusted = jsonDecode(jsonEncode(fixtures['rotated'])) as Map;
    untrusted['publisher'].remove('rotation');
    expect(
      await controller.installAutomatic(
        await read(untrusted),
        previous,
        () => true,
      ),
      false,
    );
    expect(
      await controller.installAutomatic(rotated, previous, () => true),
      true,
    );
    final unsigned = jsonDecode(jsonEncode(fixtures['rotated'])) as Map;
    unsigned.remove('publisher');
    unsigned['manifest']['version'] = '1.2.0';
    expect(
      await controller.installAutomatic(
        await read(unsigned),
        controller.byId(signed.manifest.id)!,
        () => true,
      ),
      false,
    );
  });
}
