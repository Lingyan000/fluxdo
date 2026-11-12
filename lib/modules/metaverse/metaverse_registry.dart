import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'builtin/linux_do_balance_services.dart';
import 'core/metaverse_service.dart';
import 'plugin/metaverse_plugin_service.dart';
import 'plugin/providers/metaverse_plugin_providers.dart';

/// 官方服务：随应用内置，用原生代码实现。
const List<MetaverseService> builtinMetaverseServices = [
  LdcMetaverseService(),
  CdkMetaverseService(),
];

/// 元宇宙里的全部服务：官方服务在前，第三方插件按安装顺序在后。
final metaverseServicesProvider = Provider<List<MetaverseService>>((ref) {
  final plugins = ref.watch(metaversePluginsProvider);
  return [
    ...builtinMetaverseServices,
    for (final plugin in plugins) MetaversePluginService(plugin),
  ];
});
