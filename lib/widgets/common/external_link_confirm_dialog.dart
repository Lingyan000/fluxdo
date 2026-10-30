import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import '../../config/site_customization.dart';
import '../../l10n/s.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import 'app_bottom_sheet.dart';

/// 外部链接的打开方式选择结果
enum ExternalLinkOpenChoice {
  /// 系统浏览器
  systemBrowser,

  /// 应用内置浏览器
  inAppBrowser,
}

/// 显示外部链接确认对话框
///
/// 返回用户选择的打开方式，`null` 表示取消或关闭
Future<ExternalLinkOpenChoice?> showExternalLinkConfirmDialog(
  BuildContext context,
  String url,
  LinkRiskLevel riskLevel,
) {
  return showAppBottomSheet<ExternalLinkOpenChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    enableDrag: false, // 确认弹框:禁止下滑误关
    builder: (context) =>
        _ExternalLinkConfirmSheet(url: url, riskLevel: riskLevel),
  );
}

/// 显示链接被阻止的提示
Future<void> showLinkBlockedDialog(BuildContext context, String url) {
  return showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    enableDrag: false, // 提示弹框:禁止下滑误关
    builder: (context) => _LinkBlockedSheet(url: url),
  );
}

class _ExternalLinkConfirmSheet extends StatelessWidget {
  final String url;
  final LinkRiskLevel riskLevel;

  const _ExternalLinkConfirmSheet({required this.url, required this.riskLevel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _getConfigForLevel(riskLevel, theme);
    final urlInfo = _parseUrl(url);
    // 内置浏览器（WebView）只能加载 http(s)，其余 scheme 仍交由系统处理
    final uri = Uri.tryParse(url);
    final canOpenInApp =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');

    return AppSheetScaffold(
      style: AppSheetStyle.card,
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
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
                      Symbols.language_rounded,
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
                          Symbols.content_copy_rounded,
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
                border: Border.all(color: config.color.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(
                    Symbols.warning_amber_rounded,
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
                  onPressed: () => Navigator.pop(context),
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
                  onPressed: () => Navigator.pop(
                    context,
                    ExternalLinkOpenChoice.systemBrowser,
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: config.buttonColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(context.l10n.externalLink_openInSystemBrowser),
                ),
              ),
            ],
          ),

          // 内置浏览器选项
          if (canOpenInApp) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  ExternalLinkOpenChoice.inAppBrowser,
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(
                  Symbols.open_in_browser_rounded,
                  size: 18,
                ),
                label: Text(context.l10n.externalLink_openInAppBrowser),
              ),
            ),
          ],
        ],
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
          icon: Symbols.open_in_new_rounded,
          color: theme.colorScheme.primary,
          buttonColor: theme.colorScheme.primary,
          title: l10n.externalLink_leavingTitle,
          message: l10n.externalLink_leavingMessage,
        );
      case LinkRiskLevel.risky:
        return _DialogConfig(
          icon: Symbols.link_off_rounded,
          color: Colors.orange,
          buttonColor: Colors.orange,
          title: l10n.externalLink_shortLinkTitle,
          message: l10n.externalLink_shortLinkMessage,
          warning: l10n.externalLink_shortLinkWarning,
        );
      case LinkRiskLevel.dangerous:
        return _DialogConfig(
          icon: Symbols.shield_rounded,
          color: Colors.red,
          buttonColor: Colors.red,
          title: l10n.externalLink_securityWarningTitle,
          message: l10n.externalLink_securityWarningMessage,
          warning: l10n.externalLink_securityWarningHint,
        );
      default:
        return _DialogConfig(
          icon: Symbols.open_in_new_rounded,
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

    return AppSheetScaffold(
      style: AppSheetStyle.card,
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
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
            child: const Icon(Symbols.block_rounded, color: Colors.red, size: 28),
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
              border: Border.all(color: Colors.red.withValues(alpha: 0.15)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Symbols.dangerous_rounded,
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
                  Symbols.info_rounded,
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
    );
  }
}
