import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/cdk_providers.dart';
import '../pages/webview_page.dart';
import '../services/network/exceptions/oauth_exception.dart';
import 'common/loading_spinner.dart';
import '../../../../l10n/s.dart';

class CdkBalanceCard extends ConsumerWidget {
  final bool compact;
  final bool inline;
  final bool showDivider;
  final VoidCallback? onDisable;
  final VoidCallback? onReauthorize;

  const CdkBalanceCard({
    super.key,
    this.compact = false,
    this.inline = false,
    this.showDivider = false,
    this.onDisable,
    this.onReauthorize,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cdkUserInfo = ref.watch(cdkUserInfoProvider);

    // 授权过期时强制显示错误卡片（即使有旧数据缓存）；其他错误仅在无旧数据时显示
    if (cdkUserInfo.hasError &&
        (!cdkUserInfo.hasValue || cdkUserInfo.error is OAuthExpiredException)) {
      return _buildErrorCard(context, ref, cdkUserInfo.error!);
    }

    // 加载中且无实际数据时显示加载占位
    if (cdkUserInfo.isLoading && cdkUserInfo.value == null) {
      return _buildLoadingCard(context);
    }

    final userInfo = cdkUserInfo.value;
    if (userInfo == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isRefreshing = cdkUserInfo.isLoading;

    if (inline) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => WebViewPage.open(
            context,
            'https://cdk.linux.do',
            title: 'LINUX DO CDK',
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.token_rounded,
                        size: 20,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            S.current.cdk_balance,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            '${userInfo.score}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isRefreshing)
                      LoadingSpinner(
                        size: 20,
                        color: theme.colorScheme.tertiary,
                      )
                    else
                      Icon(
                        Icons.chevron_right_rounded,
                        color: theme.colorScheme.outline.withValues(alpha: 0.4),
                        size: 20,
                      ),
                  ],
                ),
              ),
              if (showDivider)
                Padding(
                  padding: const EdgeInsets.only(left: 56),
                  child: Divider(
                    height: 1,
                    thickness: 0.5,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (compact) {
      return GestureDetector(
        onTap: () => WebViewPage.open(
          context,
          'https://cdk.linux.do',
          title: 'LINUX DO CDK',
        ),
        child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha:0.2)),
        ),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.token_rounded,
                  size: 20,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.current.cdk_balance,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    '${userInfo.score}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              if (isRefreshing) ...[
                const Spacer(),
                LoadingSpinner(
                  size: 20,
                  color: theme.colorScheme.tertiary,
                ),
              ],
            ],
          ),
        ),
      ),
      );
    }

    return GestureDetector(
      onTap: () => WebViewPage.open(
        context,
        'https://cdk.linux.do',
        title: 'LINUX DO CDK',
      ),
      child: Card(
        elevation: 8,
        shadowColor: theme.colorScheme.tertiary.withValues(alpha:0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.tertiary,
              theme.colorScheme.secondary,
            ],
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
                Icons.token_rounded,
                size: 150,
                color: Colors.white.withValues(alpha:0.1),
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
                          color: Colors.white.withValues(alpha:0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.token_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'LINUX DO CDK',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white.withValues(alpha:0.9),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (isRefreshing)
                        const LoadingSpinner(
                          size: 30,
                          color: Colors.white70,
                        )
                      else if (onDisable != null)
                        GestureDetector(
                          onTap: onDisable,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha:0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.power_settings_new_rounded,
                              color: Colors.white.withValues(alpha:0.7),
                              size: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${userInfo.score}',
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          fontSize: 36,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        S.current.cdk_points,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha:0.7),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
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
                          : theme.colorScheme.tertiaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isExpired ? Icons.lock_clock_rounded : Icons.error_outline_rounded,
                      size: 20,
                      color: isExpired
                          ? theme.colorScheme.error
                          : theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.current.cdk_balance,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          isExpired ? S.current.common_authExpired : S.current.common_loadFailed,
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
                      onPressed: () => ref.read(cdkUserInfoProvider.notifier).refresh(),
                      child: Text(S.current.common_retry),
                    ),
                ],
              ),
            ),
            if (showDivider)
              Padding(
                padding: const EdgeInsets.only(left: 56),
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
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
                      : theme.colorScheme.tertiaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isExpired ? Icons.lock_clock_rounded : Icons.error_outline_rounded,
                  size: 20,
                  color: isExpired
                      ? theme.colorScheme.error
                      : theme.colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.current.cdk_balance,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      isExpired ? S.current.common_authExpired : S.current.common_loadFailed,
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
                  onPressed: () => ref.read(cdkUserInfoProvider.notifier).refresh(),
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
          : theme.colorScheme.tertiary.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
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
                : [
                    theme.colorScheme.tertiary,
                    theme.colorScheme.secondary,
                  ],
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
                isExpired ? Icons.lock_clock_rounded : Icons.error_outline_rounded,
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
                          isExpired ? Icons.lock_clock_rounded : Icons.error_outline_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'LINUX DO CDK',
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
                              Icons.power_settings_new_rounded,
                              color: Colors.white.withValues(alpha: 0.7),
                              size: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    isExpired ? S.current.common_authExpired : S.current.common_loadFailed,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      fontSize: 28,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isExpired ? S.current.cdk_reAuthHint : S.current.common_checkNetworkRetry,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (isExpired && onReauthorize != null)
                    FilledButton.icon(
                      onPressed: onReauthorize,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(S.current.common_reAuth),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        foregroundColor: Colors.white,
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () => ref.read(cdkUserInfoProvider.notifier).refresh(),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
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
                    color: theme.colorScheme.tertiaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.token_rounded,
                    size: 20,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    S.current.cdk_balance,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                LoadingSpinner(
                  size: 16,
                  color: theme.colorScheme.tertiary,
                ),
              ],
            ),
          ),
          if (showDivider)
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Divider(
                height: 1,
                thickness: 0.5,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
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
          side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
        ),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.token_rounded,
                  size: 20,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                S.current.cdk_balance,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              LoadingSpinner(
                size: 16,
                color: theme.colorScheme.tertiary,
              ),
            ],
          ),
        ),
      );
    }

    // full 模式
    return Card(
      elevation: 8,
      shadowColor: theme.colorScheme.tertiary.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [theme.colorScheme.tertiary, theme.colorScheme.secondary],
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
              child: const Icon(Icons.token_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'LINUX DO CDK',
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
