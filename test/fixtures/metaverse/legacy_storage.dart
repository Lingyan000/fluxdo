import 'package:fluxdo/services/storage/secret_store.dart';

/// 模拟旧应用已经落盘的数据，升级测试直接写入历史命名空间。
extension LegacyPluginFixture on SecretStore {
  Future<void> writeLegacyRecord(String id, String scope, String value) =>
      write(SecretKey(namespace: 'metaverse_orders:$id', name: scope), value);

  Future<String?> readLegacyRecord(String id, String scope) =>
      read(SecretKey(namespace: 'metaverse_orders:$id', name: scope));
}
