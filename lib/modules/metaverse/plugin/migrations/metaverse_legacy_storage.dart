import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../../services/storage/secret_store.dart';

/// 将 API 1 的持久记录原样交给所属插件，具体字段由插件迁移。
/// 旧加密副本保留到用户清空数据，安装失败时旧代码仍能恢复记录。
Future<Map<String, Object?>> exportLegacyPluginStorage(
  SecretStore secrets,
  String pluginId,
  Map<String, Object?> data,
) async {
  final scope = SecretScope(namespace: 'metaverse_orders:$pluginId');
  final records = await secrets.readScope(scope);
  if (records.isEmpty) return data;
  final previous = data['legacyApi1Records'];
  final imported = data['legacyApi1Imported'];
  if ((previous != null && previous is! Map<String, dynamic>) ||
      (imported != null && imported is! Map<String, dynamic>)) {
    throw const FormatException('旧插件数据迁移记录损坏');
  }
  final exported = <String, Object?>{...?previous as Map<String, dynamic>?};
  final digests = <String, Object?>{...?imported as Map<String, dynamic>?};
  var changed = false;
  for (final entry in records.entries) {
    final name = entry.key.substring(scope.storagePrefix.length);
    final digest = sha256.convert(utf8.encode(entry.value)).toString();
    if (digests[name] == digest) continue;
    exported[name] = entry.value;
    digests[name] = digest;
    changed = true;
  }
  if (!changed) return data;
  return {
    ...data,
    'legacyApi1Records': exported,
    'legacyApi1Imported': digests,
  };
}
