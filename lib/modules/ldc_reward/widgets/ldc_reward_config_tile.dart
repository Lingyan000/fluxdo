import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/s.dart';
import '../../../pages/webview_page.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/toast_service.dart';
import '../providers/ldc_reward_provider.dart';

/// LDC 打赏凭证配置卡片（元宇宙页面用）
class LdcRewardConfigTile extends ConsumerWidget {
  const LdcRewardConfigTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final credentialsAsync = ref.watch(ldcRewardCredentialsProvider);

    final isConfigured = credentialsAsync.value != null;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: InkWell(
        onTap: () => _showConfigDialog(context, ref, isConfigured),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.volunteer_activism_rounded,
                  size: 32,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.reward_title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isConfigured ? context.l10n.reward_configured : context.l10n.reward_notConfigured,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                isConfigured ? Icons.check_circle : Icons.settings,
                color: isConfigured
                    ? Colors.green
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showConfigDialog(BuildContext context, WidgetRef ref, bool isConfigured) {
    final clientIdController = TextEditingController();
    final clientSecretController = TextEditingController();
    final theme = Theme.of(context);

    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.reward_configDialogTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.reward_configHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => WebViewPage.open(
                  ctx,
                  'https://credit.linux.do/merchant',
                  title: context.l10n.reward_createApp,
                ),
                child: Text(
                  context.l10n.reward_goToCreateApp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: clientIdController,
                decoration: const InputDecoration(
                  labelText: 'Client ID',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: clientSecretController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Client Secret',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (isConfigured)
            TextButton(
              onPressed: () {
                ref.read(ldcRewardCredentialsProvider.notifier).clear();
                Navigator.pop(ctx);
                ToastService.showSuccess(S.current.toast_credentialCleared);
              },
              child: Text(
                context.l10n.reward_clearCredential,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              final clientId = _sanitizeCredential(clientIdController.text);
              final clientSecret =
                  _sanitizeCredential(clientSecretController.text);
              if (clientId.isEmpty || clientSecret.isEmpty) {
                ToastService.showError(S.current.toast_credentialIncomplete);
                return;
              }
              ref
                  .read(ldcRewardCredentialsProvider.notifier)
                  .save(clientId, clientSecret);
              Navigator.pop(ctx);
              ToastService.showSuccess(S.current.toast_credentialSaved);
            },
            child: Text(context.l10n.common_save),
          ),
        ],
      ),
    );
  }
}

/// 清理凭证中的空白与零宽不可见字符。
/// 用户从网页 / IM 复制 Client ID / Secret 时常会混入：
///   - 普通空白（空格、Tab、换行）
///   - 零宽字符：U+200B / U+200C / U+200D（ZWSP / ZWNJ / ZWJ）
///   - U+FEFF（BOM / 零宽不换行空格）
/// 这些字符在 UI 上完全不可见，但会破坏 Basic Auth 签名导致 401。
String _sanitizeCredential(String input) {
  const invisibleCodes = <int>{0x200B, 0x200C, 0x200D, 0xFEFF};
  final buf = StringBuffer();
  for (final code in input.runes) {
    if (invisibleCodes.contains(code)) continue;
    final ch = String.fromCharCode(code);
    if (RegExp(r'\s').hasMatch(ch)) continue;
    buf.writeCharCode(code);
  }
  return buf.toString();
}
