import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/storage/secret_store.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_credential.dart';
import 'migrations/metaverse_legacy_storage.dart';

/// 已安装的第三方插件。
@immutable
class InstalledMetaversePlugin {
  const InstalledMetaversePlugin({
    required this.manifest,
    required this.source,
    this.enabled = false,
    this.suspendedReason,
    this.codeRevision,
  });

  final MetaversePluginManifest manifest;

  /// 清单地址，也是更新来源。
  final String source;
  final String? codeRevision;

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
    codeRevision: codeRevision,
    enabled: enabled ?? this.enabled,
    suspendedReason: clearSuspended
        ? null
        : (suspendedReason ?? this.suspendedReason),
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'codeRevision': ?codeRevision,
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
  final _operations = PluginOperationQueue();
  final _stagedCode = <String, String>{};
  final _credentialGenerations = <String, int>{};

  (int, int) credentialRevision(String id, String name) =>
      (_operations.generation(id), _credentialGenerations['$id/$name'] ?? 0);

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
          allowLegacyMetadata: true,
        );
        if (plugins.any((plugin) => plugin.id == manifest.id)) continue;
        plugins.add(
          InstalledMetaversePlugin(
            manifest: manifest,
            source: source,
            codeRevision: item['codeRevision'] is String
                ? item['codeRevision'] as String
                : null,
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
    if (id.length > 64 || !RegExp(r'^[a-z0-9]+([._-][a-z0-9]+)+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id');
    }
    return Directory(p.join((await _rootDirectory()).path, id));
  }

  static String revisionOf(MetaversePluginCode code) => sha256
      .convert(utf8.encode(jsonEncode({'ui': code.ui, 'script': code.script})))
      .toString();

  Future<void> writeCode(String id, MetaversePluginCode code) => _operations.run(id, () async {
    final dir = await _directory(id);
    await dir.create(recursive: true);
    final revision = revisionOf(code);
    await _atomicWrite(
      File(p.join(dir.path, 'code-$revision.json')),
      jsonEncode({'ui': code.ui, 'script': code.script}),
    );
    _stagedCode[id] = revision;
  });

  Future<MetaversePluginCode> readCode(String id) async {
    final dir = await _directory(id);
    String? revision;
    for (final installed in loadIndex()) {
      if (installed.id == id) revision = installed.codeRevision;
    }
    revision ??= _stagedCode[id];
    if (revision != null) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(revision)) {
        throw const FormatException('插件代码版本无效');
      }
      final decoded = jsonDecode(
        await File(p.join(dir.path, 'code-$revision.json')).readAsString(),
      ) as Map<String, dynamic>;
      final code = (ui: decoded['ui'] as String, script: decoded['script'] as String);
      if (revisionOf(code) != revision) throw const FormatException('插件代码摘要不匹配');
      return code;
    }
    return (
      ui: await File(p.join(dir.path, 'ui.rfwtxt')).readAsString(),
      script: await File(p.join(dir.path, 'main.js')).readAsString(),
    );
  }

  /// 文件缺失时返回空，损坏时报告错误并保留原文件。
  Future<Map<String, Object?>> readStorage(String id) async {
    final file = File(p.join((await _directory(id)).path, 'storage.json'));
    if (!await file.exists()) return {};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) throw const FormatException('插件数据损坏');
    return decoded;
  }

  /// 写入键值数据。超出容量上限时抛 [StateError]，不落盘。
  Future<void> writeStorage(String id, Map<String, Object?> data) =>
      _operations.run(id, () => _writeStorage(id, data));

  Future<Map<String, Object?>> updateStorage(String id, String key, Object? value) =>
      updateStorageEntries(id, {key: value});

  Future<Map<String, Object?>> updateStorageEntries(
    String id,
    Map<String, Object?> entries,
  ) =>
      _operations.run(id, () async {
        final data = await readStorage(id);
        for (final entry in entries.entries) {
          if (entry.value == null) {
            data.remove(entry.key);
          } else {
            data[entry.key] = entry.value;
          }
        }
        await _writeStorage(id, data);
        return data;
      });

  Future<void> importLegacyStorage(String id) => _operations.run(id, () async {
    final previous = await readStorage(id);
    final migrated = await exportLegacyPluginStorage(_secretStore, id, previous);
    if (!identical(previous, migrated)) await _writeStorage(id, migrated);
  });

  Future<void> _writeStorage(String id, Map<String, Object?> data) async {
    final encoded = jsonEncode(data);
    if (utf8.encode(encoded).length > maxStorageBytes) {
      throw StateError('插件存储超出容量上限');
    }
    final dir = await _directory(id);
    await dir.create(recursive: true);
    await _atomicWrite(File(p.join(dir.path, 'storage.json')), encoded);
  }

  Future<void> _atomicWrite(File file, String content) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> clearStorage(String id) => _operations.reset(id, () async {
    final file = File(p.join((await _directory(id)).path, 'storage.json'));
    if (await file.exists()) await file.delete();
  });

  Future<void> resetData(String id) => _operations.reset(id, () async {
    final file = File(p.join((await _directory(id)).path, 'storage.json'));
    if (await file.exists()) await file.delete();
    await _deleteToken(id);
    await clearLegacyPluginRecords(_secretStore, id);
  });

  Future<int> localBytes(String id) async {
    final directory = await _directory(id);
    if (!await directory.exists()) return 0;
    var bytes = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  /// 删除插件的全部本地文件。
  Future<void> deleteFiles(String id) => _operations.reset(id, () async {
    final dir = await _directory(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    _stagedCode.remove(id);
  });

  SecretKey _tokenKey(String id) =>
      SecretKey(namespace: _secretNamespace, name: '$id:token');

  Future<String?> readToken(String id) => _secretStore.read(_tokenKey(id));

  Future<void> writeToken(String id, String token) =>
      _operations.run(id, () => _secretStore.write(_tokenKey(id), token));

  SecretKey _sessionKey(String id) =>
      SecretKey(namespace: _secretNamespace, name: '$id:serviceSession');

  Future<void> clearLegacyRecords(String id) =>
      _operations.run(id, () =>
          clearLegacyPluginRecords(_secretStore, id));

  Future<void> deleteToken(String id) => _operations.reset(id, () => _deleteToken(id));

  Future<void> _deleteToken(String id) async {
    await Future.wait([
      _secretStore.delete(_tokenKey(id)),
      _secretStore.delete(_sessionKey(id)),
      _secretStore.deleteScope(SecretScope(namespace: 'metaverse_credentials:$id')),
    ]);
  }

  SecretKey _credentialKey(String id, String name) =>
      SecretKey(namespace: 'metaverse_credentials:$id', name: name);

  Future<MetaverseCredential?> readCredential(String id, String name) async {
    final encoded = await _secretStore.read(_credentialKey(id, name));
    if (encoded == null) return null;
    try {
      return MetaverseCredential.parse(jsonDecode(encoded));
    } on FormatException {
      return null;
    }
  }

  Future<void> writeCredential(
    String id,
    String name,
    MetaverseCredential credential, {
    required bool Function() isActive,
    required (int, int) revision,
  }) => _operations.run(id, () async {
    if (!isActive() || credentialRevision(id, name) != revision) {
      throw const PluginOperationCancelled();
    }
    await _secretStore.write(_credentialKey(id, name), jsonEncode(credential.toJson()));
  });

  Future<void> removeCredential(String id, String name) {
    final key = '$id/$name';
    _credentialGenerations[key] = (_credentialGenerations[key] ?? 0) + 1;
    return _operations.run(id, () => _secretStore.delete(_credentialKey(id, name)));
  }
}
