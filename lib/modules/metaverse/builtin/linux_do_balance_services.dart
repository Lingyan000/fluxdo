import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../ldc_reward/ldc_reward.dart';
import '../../../providers/cdk_providers.dart';
import '../../../providers/ldc_providers.dart';
import '../../../providers/theme_provider.dart';
import '../../../services/cdk_oauth_service.dart';
import '../../../services/ldc_oauth_service.dart';
import '../../../widgets/cdk_balance_card.dart';
import '../../../widgets/ldc_balance_card.dart';
import '../core/metaverse_service.dart';

/// LDC 与 CDK 的共同实现：linux.do Connect 授权 + 余额卡片。
///
/// 两者的差异只有服务标识、存储键、授权服务与卡片，其余流程完全一致，
/// 所以在这里实现一次，由子类填空。
abstract class _LinuxDoBalanceService extends MetaverseService {
  const _LinuxDoBalanceService();

  /// 开关状态的存储键（`ldc_enabled` / `cdk_enabled`）。
  String get enabledKey;

  /// 等待用户信息的首个结果，用于刷新前对齐，避免并发导致状态错乱。
  Future<void> awaitUserInfo(ProviderContainer container);

  Future<void> refreshUserInfo(ProviderContainer container);

  Future<void> disableUserInfo(ProviderContainer container);

  Future<bool> authorize(BuildContext context);

  Future<void> oauthLogout();

  Widget buildBalanceCard({
    required bool isProcessing,
    required VoidCallback onDisable,
    required VoidCallback onReauthorize,
  });

  @override
  bool isEnabled(ProviderContainer container) =>
      container.read(sharedPreferencesProvider).getBool(enabledKey) ?? false;

  @override
  Future<bool> enable(BuildContext context, ProviderContainer container) async {
    if (!await authorize(context)) return false;
    await setMetaverseServiceEnabled(container, enabledKey, true);
    await refreshUserInfo(container);
    return true;
  }

  @override
  Future<void> disable(ProviderContainer container) async {
    try {
      await oauthLogout();
    } catch (_) {
      // 忽略登出错误：本地开关和缓存必须清干净，否则界面会一直显示旧状态。
    }
    await disableUserInfo(container);
    await setMetaverseServiceEnabled(container, enabledKey, false);
  }

  @override
  Future<bool> reauthorize(
    BuildContext context,
    ProviderContainer container,
  ) async {
    if (!await authorize(context)) return false;
    await refreshUserInfo(container);
    return true;
  }

  @override
  Future<void> refresh(
    ProviderContainer container, {
    required bool Function() isActive,
  }) async {
    if (!isEnabled(container)) return;
    await awaitUserInfo(container);
    if (!isActive()) return;
    // 不等待：刷新在后台进行，界面不必等网络。
    unawaited(refreshUserInfo(container));
  }

  @override
  Widget buildCard(BuildContext context, MetaverseCardHost host) =>
      buildBalanceCard(
        isProcessing: host.isProcessing,
        onDisable: host.onDisable,
        onReauthorize: host.onReauthorize,
      );
}

/// LDC 积分服务。
class LdcMetaverseService extends _LinuxDoBalanceService {
  const LdcMetaverseService();

  @override
  String get id => 'ldc';

  @override
  String get enabledKey => LdcUserInfoNotifier.enabledKey;

  @override
  IconData get icon => Symbols.storefront_rounded;

  @override
  String title(BuildContext context) => context.l10n.metaverse_ldcService;

  @override
  String description(BuildContext context) => context.l10n.metaverse_ldcDesc;

  @override
  String enabledMessage() => S.current.metaverse_ldcAuthSuccess;

  @override
  String reauthorizedMessage() => S.current.metaverse_ldcReauthSuccess;

  @override
  Future<void> awaitUserInfo(ProviderContainer container) async {
    await container.read(ldcUserInfoProvider.future).catchError((_) => null);
  }

  @override
  Future<void> refreshUserInfo(ProviderContainer container) =>
      container.read(ldcUserInfoProvider.notifier).refresh();

  @override
  Future<void> disableUserInfo(ProviderContainer container) =>
      container.read(ldcUserInfoProvider.notifier).disable();

  @override
  Future<bool> authorize(BuildContext context) =>
      LdcOAuthService().authorize(context);

  @override
  Future<void> oauthLogout() => LdcOAuthService().logout();

  @override
  Widget? buildExtras(BuildContext context) => const LdcRewardConfigTile();

  @override
  Widget buildBalanceCard({
    required bool isProcessing,
    required VoidCallback onDisable,
    required VoidCallback onReauthorize,
  }) => LdcBalanceCard(
    isProcessing: isProcessing,
    onDisable: onDisable,
    onReauthorize: onReauthorize,
  );
}

/// CDK 服务。
class CdkMetaverseService extends _LinuxDoBalanceService {
  const CdkMetaverseService();

  @override
  String get id => 'cdk';

  @override
  String get enabledKey => CdkUserInfoNotifier.enabledKey;

  @override
  IconData get icon => Symbols.token_rounded;

  @override
  bool get useTertiaryTone => true;

  @override
  String title(BuildContext context) => context.l10n.metaverse_cdkService;

  @override
  String description(BuildContext context) => context.l10n.metaverse_cdkDesc;

  @override
  String enabledMessage() => S.current.metaverse_cdkAuthSuccess;

  @override
  String reauthorizedMessage() => S.current.metaverse_cdkReauthSuccess;

  @override
  Future<void> awaitUserInfo(ProviderContainer container) async {
    await container.read(cdkUserInfoProvider.future).catchError((_) => null);
  }

  @override
  Future<void> refreshUserInfo(ProviderContainer container) =>
      container.read(cdkUserInfoProvider.notifier).refresh();

  @override
  Future<void> disableUserInfo(ProviderContainer container) =>
      container.read(cdkUserInfoProvider.notifier).disable();

  @override
  Future<bool> authorize(BuildContext context) =>
      CdkOAuthService().authorize(context);

  @override
  Future<void> oauthLogout() => CdkOAuthService().logout();

  @override
  Widget buildBalanceCard({
    required bool isProcessing,
    required VoidCallback onDisable,
    required VoidCallback onReauthorize,
  }) => CdkBalanceCard(
    isProcessing: isProcessing,
    onDisable: onDisable,
    onReauthorize: onReauthorize,
  );
}

/// 写入服务开关状态。
Future<void> setMetaverseServiceEnabled(
  ProviderContainer container,
  String key,
  bool value,
) async {
  // 与服务自身缓存的是同一个 SharedPreferences 实例，测试里可被覆盖。
  final prefs = container.read(sharedPreferencesProvider);
  await prefs.setBool(key, value);
}
