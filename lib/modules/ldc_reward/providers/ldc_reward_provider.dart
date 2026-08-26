import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/s.dart';
import '../../../services/account_manager.dart';
import '../../../services/auth_session.dart';
import '../../../providers/secret_store_provider.dart';
import '../../../providers/theme_provider.dart' show sharedPreferencesProvider;
import '../../../providers/core_providers.dart';
import '../models/ldc_reward_credentials.dart';
import '../models/reward_request.dart';
import '../models/reward_result.dart';
import '../services/ldc_reward_credential_store.dart';
import '../services/ldc_reward_service.dart';

/// 凭证管理 Provider
final ldcRewardCredentialsProvider =
    AsyncNotifierProvider<LdcRewardCredentialsNotifier, LdcRewardCredentials?>(
      LdcRewardCredentialsNotifier.new,
    );

final ldcRewardCredentialStoreProvider = Provider<LdcRewardCredentialStore>((
  ref,
) {
  // 未解析出当前用户时也不能回退到 device key；guest 是独立的默认
  // profile，保证登录切换窗口不会短暂暴露上一个账号的打赏凭证。
  final username = ref.watch(
    currentUserProvider.select((value) => value.value?.username),
  );
  return LdcRewardCredentialStore(
    secretStore: ref.watch(secretStoreProvider),
    preferences: ref.watch(sharedPreferencesProvider),
    accountId: username ?? AccountManager.guestAccountId,
  );
});

class LdcRewardCredentialsNotifier
    extends AsyncNotifier<LdcRewardCredentials?> {
  Future<void> _mutationQueue = Future.value();

  @override
  Future<LdcRewardCredentials?> build() async {
    final generation = AuthSession().generation;
    final store = ref.watch(ldcRewardCredentialStoreProvider);
    final credentials = await store.load();
    return AuthSession().isValid(generation) ? credentials : null;
  }

  /// 保存凭证
  Future<void> save(String clientId, String clientSecret) {
    final credentials = LdcRewardCredentials(
      clientId: clientId,
      clientSecret: clientSecret,
    );
    final generation = AuthSession().generation;
    final store = ref.read(ldcRewardCredentialStoreProvider);
    return _enqueueMutation(() async {
      if (!AuthSession().isValid(generation)) return;
      await store.save(credentials);
      if (!AuthSession().isValid(generation)) return;
      state = AsyncData(credentials);
    });
  }

  /// 清除凭证
  Future<void> clear() {
    final generation = AuthSession().generation;
    final store = ref.read(ldcRewardCredentialStoreProvider);
    return _enqueueMutation(() async {
      if (!AuthSession().isValid(generation)) return;
      await store.clear();
      if (!AuthSession().isValid(generation)) return;
      state = const AsyncData(null);
    });
  }

  Future<void> _enqueueMutation(Future<void> Function() operation) {
    final next = _mutationQueue
        .catchError((Object _) {})
        .then((_) => operation());
    _mutationQueue = next;
    return next;
  }
}

/// 打赏防重复管理
/// 同一 topicId_postId_userId 在 2 分钟内不可重复打赏
class _RewardCooldown {
  static final Map<String, DateTime> _pending = {};
  static const _cooldown = Duration(minutes: 2);

  static String _key(int topicId, int postId, int userId) =>
      '${topicId}_${postId}_$userId';

  /// 检查是否在冷却期内，返回剩余秒数；不在冷却期返回 null
  static int? check(int topicId, int postId, int userId) {
    final key = _key(topicId, postId, userId);
    final expireAt = _pending[key];
    if (expireAt == null) return null;
    final remaining = expireAt.difference(DateTime.now()).inSeconds;
    if (remaining <= 0) {
      _pending.remove(key);
      return null;
    }
    return remaining;
  }

  static void mark(int topicId, int postId, int userId) {
    _pending[_key(topicId, postId, userId)] = DateTime.now().add(_cooldown);
  }
}

/// 检查打赏冷却期，返回剩余秒数；不在冷却期返回 null
int? checkRewardCooldown({
  required int topicId,
  required int postId,
  required int userId,
}) => _RewardCooldown.check(topicId, postId, userId);

/// 执行打赏
Future<LdcRewardResult> executeReward({
  required LdcRewardCredentials credentials,
  required int userId,
  required String username,
  required double amount,
  required int topicId,
  required int postId,
  String? remark,
}) async {
  // 防重复检查
  final remaining = _RewardCooldown.check(topicId, postId, userId);
  if (remaining != null) {
    return LdcRewardResult.error(S.current.reward_duplicateWarning(remaining));
  }

  final service = LdcRewardService(
    clientId: credentials.clientId,
    clientSecret: credentials.clientSecret,
  );

  final request = LdcRewardRequest(
    userId: userId,
    username: username,
    amount: amount,
    outTradeNo: LdcRewardRequest.generateTradeNo(topicId, postId),
    remark: remark,
  );

  final result = await service.distribute(request);

  // 成功后标记冷却
  if (result.success) {
    _RewardCooldown.mark(topicId, postId, userId);
  }

  return result;
}
