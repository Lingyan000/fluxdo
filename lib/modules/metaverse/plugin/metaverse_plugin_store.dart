import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/storage/secret_store.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_service_session.dart';

/// 已安装的第三方插件。
@immutable
class InstalledMetaversePlugin {
  const InstalledMetaversePlugin({
    required this.manifest,
    required this.source,
    this.enabled = false,
    this.suspendedReason,
  });

  final MetaversePluginManifest manifest;

  /// 清单地址，也是更新来源。
  final String source;

  /// 用户是否已开启（并完成授权）。
  final bool enabled;

  /// 非空表示因脚本无响应被宿主暂停，需用户手动恢复。
  final String? suspendedReason;

  String get id => manifest.id;

  InstalledMetaversePlugin copyWith({
    bool? enabled,
    String? suspendedReason,
    bool clearSuspended = false,
  }) => InstalledMetaversePlugin(
    manifest: manifest,
    source: source,
    enabled: enabled ?? this.enabled,
    suspendedReason: clearSuspended
        ? null
        : (suspendedReason ?? this.suspendedReason),
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'enabled': enabled,
    'suspended': ?suspendedReason,
    'manifest': manifest.raw,
  };
}

/// 插件包的两个代码文件。
typedef MetaversePluginCode = ({String ui, String script});

/// 第三方插件的本地持久化。
///
/// - 索引（来源、开关、清单原文）放 SharedPreferences：链接路由要同步拿到
///   已开启插件的规则，不能等文件 IO。
/// - 界面描述、脚本、插件自己的键值数据放应用支持目录下的独立文件夹。
/// - 访问凭证放系统安全存储，不允许降级到明文。
///
/// 清单每次读取都重新校验：站点域名等校验规则变严后，旧清单不会绕过。
class MetaversePluginStore {
  MetaversePluginStore({
    required this._preferences,
    required this._secretStore,
    required this._rootDirectory,
    this.reservedHosts = const [],
  });

  static const indexKey = 'metaverse_plugins_v1';
  static const maxStorageBytes = 256 * 1024;
  static const _secretNamespace = 'metaverse_plugin';

  final SharedPreferences _preferences;
  final SecretStore _secretStore;
  final Future<Directory> Function() _rootDirectory;
  final List<String> reservedHosts;

  /// 读取已安装插件；清单已不合法的条目直接跳过。
  List<InstalledMetaversePlugin> loadIndex() {
    final encoded = _preferences.getString(indexKey);
    if (encoded == null) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final plugins = <InstalledMetaversePlugin>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final source = item['source'];
      if (source is! String) continue;
      try {
        final manifest = MetaversePluginManifest.parse(
          item['manifest'],
          reservedHosts: reservedHosts,
        );
        if (plugins.any((plugin) => plugin.id == manifest.id)) continue;
        plugins.add(
          InstalledMetaversePlugin(
            manifest: manifest,
            source: source,
            enabled: item['enabled'] == true,
            suspendedReason: item['suspended'] is String
                ? item['suspended'] as String
                : null,
          ),
        );
      } on MetaverseManifestException catch (error) {
        debugPrint('[Metaverse] 跳过不合法的已安装插件: $error');
      }
    }
    return plugins;
  }

  Future<void> saveIndex(List<InstalledMetaversePlugin> plugins) async {
    final saved = await _preferences.setString(
      indexKey,
      jsonEncode([for (final plugin in plugins) plugin.toJson()]),
    );
    if (!saved) throw StateError('插件索引保存失败');
  }

  Future<Directory> _directory(String id) async {
    // id 已由清单校验限制为 [a-z0-9._-]，这里再防一道目录穿越。
    if (id.contains('/') || id.contains(r'\') || id.contains('..')) {
      throw ArgumentError.value(id, 'id');
    }
    return Directory(p.join((await _rootDirectory()).path, id));
  }

  Future<void> writeCode(String id, MetaversePluginCode code) async {
    final dir = await _directory(id);
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'ui.rfwtxt')).writeAsString(code.ui);
    await File(p.join(dir.path, 'main.js')).writeAsString(code.script);
  }

  Future<MetaversePluginCode> readCode(String id) async {
    final dir = await _directory(id);
    return (
      ui: await File(p.join(dir.path, 'ui.rfwtxt')).readAsString(),
      script: await File(p.join(dir.path, 'main.js')).readAsString(),
    );
  }

  /// 读取插件自己的键值数据；文件缺失或损坏时返回空。
  Future<Map<String, Object?>> readStorage(String id) async {
    final file = File(p.join((await _directory(id)).path, 'storage.json'));
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  /// 写入键值数据。超出容量上限时抛 [StateError]，不落盘。
  Future<void> writeStorage(String id, Map<String, Object?> data) async {
    final encoded = jsonEncode(data);
    if (utf8.encode(encoded).length > maxStorageBytes) {
      throw StateError('插件存储超出容量上限');
    }
    final dir = await _directory(id);
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'storage.json')).writeAsString(encoded);
  }

  Future<void> clearStorage(String id) async {
    final file = File(p.join((await _directory(id)).path, 'storage.json'));
    if (await file.exists()) await file.delete();
  }

  /// 删除插件的全部本地文件。
  Future<void> deleteFiles(String id) async {
    final dir = await _directory(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  SecretKey _tokenKey(String id) =>
      SecretKey(namespace: _secretNamespace, name: '$id:token');

  Future<String?> readToken(String id) => _secretStore.read(_tokenKey(id));

  Future<void> writeToken(String id, String token) =>
      _secretStore.write(_tokenKey(id), token);

  SecretKey _sessionKey(String id) =>
      SecretKey(namespace: _secretNamespace, name: '$id:serviceSession');

  // 同一个存储实例跨脚本重启共用；旧请求尚在飞行时新实例不能再发一次。
  final _orderLocks = <String>{};
  Future<T> withOrderLock<T>(String id, Future<T> Function() run) async {
    if (!_orderLocks.add(id)) throw StateError('checkout_busy');
    try {
      return await run();
    } finally {
      _orderLocks.remove(id);
    }
  }

  SecretKey _orderKey(String id, String scope) =>
      SecretKey(namespace: 'metaverse_orders:$id', name: scope);
  Future<String?> readOrder(String id, String scope) =>
      _secretStore.read(_orderKey(id, scope));
  Future<void> writeOrder(String id, String scope, String encoded) =>
      _secretStore.write(_orderKey(id, scope), encoded);
  Future<void> forgetOrder(String id, String scope) =>
      _secretStore.delete(_orderKey(id, scope));
  Future<void> clearOrders(String id) =>
      _secretStore.deleteScope(SecretScope(namespace: 'metaverse_orders:$id'));

  Future<MetaverseServiceSession?> readServiceSession(String id) async {
    final encoded = await _secretStore.read(_sessionKey(id));
    // 手填凭证没有服务签发记录，不能升级成托管会话。
    if (encoded == null) return null;
    try {
      return MetaverseServiceSession.parse(jsonDecode(encoded));
    } on FormatException {
      return null;
    }
  }

  /// 仅限宿主接收已验证的签发结果时调用；脚本和手填凭证对话框没有此入口。
  Future<void> writeServiceSession(
    String id,
    MetaverseServiceSession session,
  ) async {
    await _secretStore.delete(_tokenKey(id));
    await _secretStore.write(_sessionKey(id), jsonEncode(session.toJson()));
  }

  Future<void> deleteToken(String id) async {
    await Future.wait([
      _secretStore.delete(_tokenKey(id)),
      _secretStore.delete(_sessionKey(id)),
    ]);
  }
}
