import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/core_providers.dart';
import '../providers/ldc_providers.dart';
import '../pages/webview_page.dart';
import '../services/network/exceptions/oauth_exception.dart';
import '../utils/number_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../../l10n/s.dart';

class LdcBalanceCard extends ConsumerWidget {
  static const String _homeUrl = 'https://credit.linux.do/home';

  final bool compact;
  final bool inline;
  final VoidCallback? onDisable;
  final VoidCallback? onReauthorize;

  const LdcBalanceCard({
    super.key,
    this.compact = false,
    this.inline = false,
    this.onDisable,
    this.onReauthorize,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ldcUserInfo = ref.watch(ldcUserInfoProvider);

    // 授权过期时强制显示错误卡片（即使有旧数据缓存）；其他错误仅在无旧数据时显示
    if (ldcUserInfo.hasError &&
        (!ldcUserInfo.hasValue || ldcUserInfo.error is OAuthExpiredException)) {
      return _buildErrorCard(context, ref, ldcUserInfo.error!);
    }

    // 加载中且无实际数据时显示加载占位
    if (ldcUserInfo.isLoading && ldcUserInfo.value == null) {
      return _buildLoadingCard(context);
    }

    final userInfo = ldcUserInfo.value;
    if (userInfo == null) return const SizedBox.shrink();

    // 今日收益依赖 Discourse 侧的 gamification_score，与 LDC 数据各自独立到达；
    // 未就绪时返回 null，徽章不渲染（而不是显示错误的 +0）
    final gamificationScore = ref.watch(
      currentUserProvider.select((value) => value.value?.gamificationScore),
    );
    final dailyIncome = _dailyIncome(
      gamificationScore,
      userInfo.communityBalance,
    );
    final dailyIncomeText = dailyIncome == null
        ? null
        : NumberUtils.formatSignedInt(dailyIncome);

    final theme = Theme.of(context);
    final isRefreshing = ldcUserInfo.isLoading;

    if (inline) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () =>
              WebViewPage.open(context, _homeUrl, title: 'LINUX DO Credits'),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Symbols.account_balance_wallet_rounded,
                        size: 20,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            S.current.ldc_balance,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            userInfo.availableBalance,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (dailyIncomeText != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Symbols.trending_up_rounded,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              dailyIncomeText,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(width: 8),
                    if (isRefreshing)
                      LoadingSpinner(size: 20, color: theme.colorScheme.primary)
                    else
                      Icon(
                        Symbols.chevron_right_rounded,
                        color: theme.colorScheme.outline.withValues(alpha: 0.4),
                        size: 20,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (compact) {
      return GestureDetector(
        onTap: () =>
            WebViewPage.open(context, _homeUrl, title: 'LINUX DO Credits'),
        child: Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
            ),
          ),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.account_balance_wallet_rounded,
                    size: 20,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.current.ldc_balance,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      userInfo.availableBalance,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                if (dailyIncomeText != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.trending_up_rounded,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          dailyIncomeText,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (isRefreshing) ...[
                  const SizedBox(width: 8),
                  LoadingSpinner(size: 20, color: theme.colorScheme.primary),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () =>
          WebViewPage.open(context, _homeUrl, title: 'LINUX DO Credits'),
      child: Card(
        elevation: 8,
        shadowColor: theme.colorScheme.primary.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            children: [
              // 装饰背景
              Positioned(
                right: -20,
                top: -20,
                child: Icon(
                  Symbols.account_balance_wallet_rounded,
                  size: 150,
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Symbols.auto_awesome_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'LINUX DO Credits',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.9),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        if (isRefreshing)
                          const LoadingSpinner(size: 30, color: Colors.white70)
                        else if (onDisable != null)
                          GestureDetector(
                            onTap: onDisable,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Symbols.power_settings_new_rounded,
                                color: Colors.white.withValues(alpha: 0.7),
                                size: 18,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      userInfo.availableBalance,
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        fontSize: 36,
                      ),
                    ),
                    if (dailyIncomeText != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Symbols.trending_up_rounded,
                              color: Colors.greenAccent,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              S.current.ldc_dailyIncome(dailyIncomeText),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 今日收益 = Discourse gamification 积分 - 已结算的社区余额。
  /// score 未就绪时返回 null（不渲染徽章）；余额可能是小数字符串，用 double 解析
  int? _dailyIncome(int? gamificationScore, String communityBalance) {
    if (gamificationScore == null) return null;
    final balance = double.tryParse(communityBalance) ?? 0;
    return (gamificationScore - balance).round();
  }

  Widget _buildErrorCard(BuildContext context, WidgetRef ref, Object error) {
    final theme = Theme.of(context);
    final isExpired = error is OAuthExpiredException;

    if (inline) {
      return Material(
        color: Colors.transparent,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isExpired
                          ? theme.colorScheme.error.withValues(alpha: 0.1)
                          : theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isExpired
                          ? Symbols.lock_clock_rounded
                          : Symbols.error_rounded,
                      size: 20,
                      color: isExpired
                          ? theme.colorScheme.error
                          : theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.current.ldc_balance,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          isExpired
                              ? S.current.common_authExpired
                              : S.current.common_loadFailed,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isExpired
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isExpired && onReauthorize != null)
                    TextButton(
                      onPressed: onReauthorize,
                      child: Text(S.current.common_reAuth),
                    )
                  else
                    TextButton(
                      onPressed: () =>
                          ref.read(ldcUserInfoProvider.notifier).refresh(),
                      child: Text(S.current.common_retry),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (compact) {
      return Card(
        elevation: 0,
        color: isExpired
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isExpired
                ? theme.colorScheme.error.withValues(alpha: 0.3)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isExpired
                      ? theme.colorScheme.error.withValues(alpha: 0.1)
                      : theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isExpired
                      ? Symbols.lock_clock_rounded
                      : Symbols.error_rounded,
                  size: 20,
                  color: isExpired
                      ? theme.colorScheme.error
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.current.ldc_balance,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      isExpired
                          ? S.current.common_authExpired
                          : S.current.common_loadFailed,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isExpired
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              if (isExpired && onReauthorize != null)
                TextButton(
                  onPressed: onReauthorize,
                  child: Text(S.current.common_reAuth),
                )
              else
                TextButton(
                  onPressed: () =>
                      ref.read(ldcUserInfoProvider.notifier).refresh(),
                  child: Text(S.current.common_retry),
                ),
            ],
          ),
        ),
      );
    }

    // full 模式错误卡片
    return Card(
      elevation: 8,
      shadowColor: isExpired
          ? theme.colorScheme.error.withValues(alpha: 0.3)
          : theme.colorScheme.primary.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isExpired
                ? [
                    theme.colorScheme.error.withValues(alpha: 0.8),
                    theme.colorScheme.error.withValues(alpha: 0.6),
                  ]
                : [theme.colorScheme.primary, theme.colorScheme.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -20,
              top: -20,
              child: Icon(
                isExpired
                    ? Symbols.lock_clock_rounded
                    : Symbols.error_rounded,
                size: 150,
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isExpired
                              ? Symbols.lock_clock_rounded
                              : Symbols.error_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'LINUX DO Credits',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white.withValues(alpha: 0.9),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (onDisable != null)
                        GestureDetector(
                          onTap: onDisable,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Symbols.power_settings_new_rounded,
                              color: Colors.white.withValues(alpha: 0.7),
                              size: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    isExpired
                        ? S.current.common_authExpired
                        : S.current.common_loadFailed,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      fontSize: 28,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isExpired
                        ? S.current.ldc_reAuthHint
                        : S.current.common_checkNetworkRetry,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (isExpired && onReauthorize != null)
                    FilledButton.icon(
                      onPressed: onReauthorize,
                      icon: const Icon(Symbols.refresh_rounded, size: 18),
                      label: Text(S.current.common_reAuth),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        foregroundColor: Colors.white,
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () =>
                          ref.read(ldcUserInfoProvider.notifier).refresh(),
                      icon: const Icon(Symbols.refresh_rounded, size: 18),
                      label: Text(S.current.common_retry),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        foregroundColor: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard(BuildContext context) {
    final theme = Theme.of(context);

    if (inline) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Symbols.account_balance_wallet_rounded,
                    size: 20,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // loading 态保持与数据态相同的两行结构（标题 + 占位余额），
                  // 避免数据到达后由一行变两行导致的卡片高度跳变
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S.current.ldc_balance,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '—',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                LoadingSpinner(size: 20, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ],
      );
    }

    if (compact) {
      return Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
          ),
        ),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Symbols.account_balance_wallet_rounded,
                  size: 20,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                S.current.ldc_balance,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              LoadingSpinner(size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
      );
    }

    // full 模式
    return Card(
      elevation: 8,
      shadowColor: theme.colorScheme.primary.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Symbols.auto_awesome_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'LINUX DO Credits',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const LoadingSpinner(size: 16, color: Colors.white),
          ],
        ),
      ),
    );
  }
}
