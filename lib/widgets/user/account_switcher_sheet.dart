import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/app_state_refresher.dart';
import '../../services/account_manager.dart';
import '../../services/toast_service.dart';
import '../../utils/url_helper.dart';
import '../../pages/account_manage_page.dart';
import '../common/app_bottom_sheet.dart';

/// 长按底栏「我的」弹出的快速切换账号面板。
///
/// 只做「列出 + 一键切换」：快捷手势场景下去掉账号管理页的确认弹窗，
/// 切换成功/失败的收口与 [AccountManagePage] 完全一致
/// （[AppStateRefresher.resetForAccountSwitch] 强制全量刷新，避免脏缓存）。
/// 移除账号、添加账号等完整管理仍走账号管理页（面板底部入口）。
abstract final class AccountSwitcherSheet {
  static Future<void> show(BuildContext context) {
    return AppBottomSheet.show(
      context: context,
      title: context.l10n.accountManage_title,
      builder: (_) => const _AccountSwitcherBody(),
    );
  }
}

class _AccountSwitcherBody extends StatefulWidget {
  const _AccountSwitcherBody();

  @override
  State<_AccountSwitcherBody> createState() => _AccountSwitcherBodyState();
}

class _AccountSwitcherBodyState extends State<_AccountSwitcherBody> {
  final AccountManager _manager = AccountManager();
  List<SavedAccount> _accounts = const [];
  String? _currentUsername;
  bool _loading = true;

  /// 正在切换的目标用户名；非 null 时列表被进度态替换。
  String? _switchingUsername;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    // 与账号管理页一致：先固化当前登录态，保证切走后还能切回来
    await _manager.syncCurrentAccount();
    final accounts = await _manager.listAccounts();
    final current = await _manager.getCurrentUsername();
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _currentUsername = current;
      _loading = false;
    });
  }

  Future<void> _switchTo(SavedAccount account) async {
    if (_switchingUsername != null) return;
    setState(() => _switchingUsername = account.username);
    try {
      await _manager.switchToAccount(account.username);
      if (!mounted) return;
      // 清理与上一账号绑定的缓存并强制全量刷新（绕过 refreshAll 去抖）
      await AppStateRefresher.resetForAccountSwitch(
        ProviderScope.containerOf(context, listen: false),
      );
      if (!mounted) return;
      ToastService.showSuccess(context.l10n.accountManage_switchDone);
      Navigator.of(context).pop();
    } on AccountSessionExpiredException {
      if (!mounted) return;
      ToastService.showError(
        context.l10n.accountManage_sessionExpired(account.username),
      );
      setState(() => _switchingUsername = null);
    } catch (_) {
      if (!mounted) return;
      ToastService.showError(context.l10n.accountManage_switchFailed);
      setState(() => _switchingUsername = null);
    }
  }

  Future<void> _openManagePage() async {
    final navigator = Navigator.of(context);
    navigator.pop();
    unawaited(
      navigator.push(
        MaterialPageRoute(builder: (_) => const AccountManagePage()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: LoadingSpinner(),
        ),
      );
    }

    if (_switchingUsername != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LoadingSpinner(),
              const SizedBox(height: 16),
              Text(
                l10n.accountManage_switching,
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final account in _accounts)
          _AccountTile(
            account: account,
            isCurrent: account.username == _currentUsername,
            onTap: account.username == _currentUsername
                ? null
                : () => unawaited(_switchTo(account)),
          ),
        if (_accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              l10n.accountManage_empty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const Divider(height: 1),
        InkWell(
          onTap: _openManagePage,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Symbols.manage_accounts_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    l10n.accountManage_title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                Icon(
                  Symbols.chevron_right_rounded,
                  size: 20,
                  color: theme.colorScheme.outline.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isCurrent,
    required this.onTap,
  });

  final SavedAccount account;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    final template = account.avatarTemplate;
    final Widget avatar;
    if (template != null && template.isNotEmpty) {
      final url = UrlHelper.resolveUrlWithCdn(
        template.replaceAll('{size}', '96'),
      );
      avatar = CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        foregroundImage: NetworkImage(url),
      );
    } else {
      avatar = CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Text(
          account.username.isNotEmpty ? account.username[0].toUpperCase() : '?',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                account.username,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (isCurrent)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  l10n.accountManage_currentChip,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
