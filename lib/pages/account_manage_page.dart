import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../services/account_manager.dart';
import '../l10n/s.dart';
import '../services/toast_service.dart';
import '../utils/url_helper.dart';
import 'login_page.dart';

/// 账号管理页：多账号列表、切换、移除、添加账号。
///
/// 切换/移除的实际会话操作在 [AccountManager]；本页只做确认交互与状态展示。
class AccountManagePage extends ConsumerStatefulWidget {
  const AccountManagePage({super.key});

  @override
  ConsumerState<AccountManagePage> createState() => _AccountManagePageState();
}

class _AccountManagePageState extends ConsumerState<AccountManagePage> {
  final AccountManager _manager = AccountManager();
  List<SavedAccount> _accounts = const [];
  String? _currentUsername;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    // 当前有登录态时先固化一份最新快照，保证之后切走还能切回来
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
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.accountManage_switchConfirmTitle),
        content: Text(
          l10n.accountManage_switchConfirmMessage(account.username),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.accountManage_switchConfirmTitle),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 全屏进度遮罩：切换涉及预加载刷新，秒级耗时
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(context.l10n.accountManage_switching),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await _manager.switchToAccount(account.username);
      if (!mounted) return;
      ToastService.showSuccess(context.l10n.accountManage_switchDone);
    } on AccountSessionExpiredException {
      if (!mounted) return;
      ToastService.showError(
        context.l10n.accountManage_sessionExpired(account.username),
      );
    } catch (e) {
      if (!mounted) return;
      ToastService.showError(context.l10n.accountManage_switchFailed);
    } finally {
      if (mounted) {
        final navigator = Navigator.of(context);
        navigator.pop(); // 关进度遮罩
        await _reload();
      }
    }
  }

  Future<void> _removeAccount(SavedAccount account) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.accountManage_removeConfirmTitle),
        content: Text(
          l10n.accountManage_removeConfirmMessage(account.username),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.accountManage_removeConfirmTitle),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _manager.removeAccount(account.username);
    if (!mounted) return;
    ToastService.showInfo(context.l10n.accountManage_removed);
    await _reload();
  }

  Future<void> _addAccount() async {
    await _manager.syncCurrentAccount(); // 新登录会覆盖 jar 会话,先把当前账号固化
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountManage_title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                SegmentedCardGroup(
                  children: [
                    for (final account in _accounts)
                      _buildAccountTile(theme, l10n, account),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedCardGroup(
                  children: [
                    InkWell(
                      onTap: _addAccount,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.1,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Symbols.person_add_rounded,
                                color: theme.colorScheme.primary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                l10n.accountManage_addAccount,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_accounts.isEmpty) ...[
                  const SizedBox(height: 32),
                  Center(
                    child: Text(
                      l10n.accountManage_empty,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildAccountTile(
    ThemeData theme,
    AppLocalizations l10n,
    SavedAccount account,
  ) {
    final isCurrent = account.username == _currentUsername;
    return InkWell(
      onTap: isCurrent ? null : () => _switchTo(account),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _buildAvatar(theme, account),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.username,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
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
              )
            else ...[
              IconButton(
                icon: Icon(
                  Symbols.delete_outline_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                tooltip: l10n.accountManage_removeConfirmTitle,
                onPressed: () => _removeAccount(account),
              ),
              Icon(
                Symbols.chevron_right_rounded,
                color: theme.colorScheme.outline.withValues(alpha: 0.4),
                size: 20,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, SavedAccount account) {
    final template = account.avatarTemplate;
    if (template != null && template.isNotEmpty) {
      final url = UrlHelper.resolveUrlWithCdn(
        template.replaceAll('{size}', '96'),
      );
      return CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        foregroundImage: NetworkImage(url),
      );
    }
    return CircleAvatar(
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
}
