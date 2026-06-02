import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../config/site_customization.dart';
import '../../l10n/s.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';

/// 显示外部链接确认对话框
///
/// 返回 `true` 表示用户确认继续访问，`false` 或 `null` 表示取消
Future<bool?> showExternalLinkConfirmDialog(
  BuildContext context,
  String url,
  LinkRiskLevel riskLevel,
) {
  return showAppBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _ExternalLinkConfirmSheet(
      url: url,
      riskLevel: riskLevel,
    ),
  );
}

/// 显示链接被阻止的提示
Future<void> showLinkBlockedDialog(BuildContext context, String url) {
  return showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _LinkBlockedSheet(url: url),
  );
}

class _ExternalLinkConfirmSheet extends StatelessWidget {
  final String url;
  final LinkRiskLevel riskLevel;

  const _ExternalLinkConfirmSheet({
    required this.url,
    required this.riskLevel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _getConfigForLevel(riskLevel, theme);
    final urlInfo = _parseUrl(url);

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部图标和标题
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: config.color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(config.icon, color: config.color, size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                config.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                config.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 20),

              // URL 显示区域
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 域名高亮显示
                    Row(
                      children: [
                        Icon(
                          Icons.language_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            urlInfo.host,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 复制按钮
                        GestureDetector(
                          onTap: () => _copyUrl(context),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (urlInfo.path.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        urlInfo.path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),

              // 警告提示
              if (config.warning != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: config.color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: config.color.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: config.color,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          config.warning!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: config.color,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // 操作按钮
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(context.l10n.common_cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: config.buttonColor,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(context.l10n.common_continueVisit),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copyUrl(BuildContext context) {
    Clipboard.setData(ClipboardData(text: url));
    ToastService.showSuccess(S.current.common_linkCopied);
  }

  _UrlInfo _parseUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return _UrlInfo(host: url, path: '');
    final path = uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}';
    return _UrlInfo(host: uri.host, path: path);
  }

  _DialogConfig _getConfigForLevel(LinkRiskLevel level, ThemeData theme) {
    final l10n = S.current;
    switch (level) {
      case LinkRiskLevel.normal:
        return _DialogConfig(
          icon: Icons.open_in_new_rounded,
          color: theme.colorScheme.primary,
          buttonColor: theme.colorScheme.primary,
          title: l10n.externalLink_leavingTitle,
          message: l10n.externalLink_leavingMessage,
        );
      case LinkRiskLevel.risky:
        return _DialogConfig(
          icon: Icons.link_off_rounded,
          color: Colors.orange,
          buttonColor: Colors.orange,
          title: l10n.externalLink_shortLinkTitle,
          message: l10n.externalLink_shortLinkMessage,
          warning: l10n.externalLink_shortLinkWarning,
        );
      case LinkRiskLevel.dangerous:
        return _DialogConfig(
          icon: Icons.shield_outlined,
          color: Colors.red,
          buttonColor: Colors.red,
          title: l10n.externalLink_securityWarningTitle,
          message: l10n.externalLink_securityWarningMessage,
          warning: l10n.externalLink_securityWarningHint,
        );
      default:
        return _DialogConfig(
          icon: Icons.open_in_new_rounded,
          color: theme.colorScheme.primary,
          buttonColor: theme.colorScheme.primary,
          title: l10n.externalLink_leavingTitle,
          message: l10n.externalLink_leavingMessage,
        );
    }
  }
}

class _UrlInfo {
  final String host;
  final String path;

  _UrlInfo({required this.host, required this.path});
}

class _DialogConfig {
  final IconData icon;
  final Color color;
  final Color buttonColor;
  final String title;
  final String message;
  final String? warning;

  const _DialogConfig({
    required this.icon,
    required this.color,
    required this.buttonColor,
    required this.title,
    required this.message,
    this.warning,
  });
}

class _LinkBlockedSheet extends StatelessWidget {
  final String url;

  const _LinkBlockedSheet({required this.url});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? url;

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部图标
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.block_rounded, color: Colors.red, size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n.externalLink_blocked,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.externalLink_blockedMessage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 20),

              // 域名显示
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.red.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.dangerous_rounded,
                      size: 18,
                      color: Colors.red.shade400,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        host,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // 提示信息
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.l10n.externalLink_contactAdmin,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // 确认按钮
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(context.l10n.common_understood),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
