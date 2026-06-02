import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/hcaptcha_accessibility_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/toast_service.dart';
import '../../hcaptcha_accessibility_page.dart';

/// hCaptcha 无障碍设置卡片
class HCaptchaAccessibilityCard extends StatefulWidget {
  const HCaptchaAccessibilityCard({super.key});

  @override
  State<HCaptchaAccessibilityCard> createState() =>
      _HCaptchaAccessibilityCardState();
}

class _HCaptchaAccessibilityCardState extends State<HCaptchaAccessibilityCard> {
  final _service = HCaptchaAccessibilityService();

  @override
  void initState() {
    super.initState();
    _service.enabledNotifier.addListener(_onChanged);
    _service.cookieNotifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.enabledNotifier.removeListener(_onChanged);
    _service.cookieNotifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = _service.enabled;
    final hasCookie =
        _service.cookie != null && _service.cookie!.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: Text(context.l10n.hcaptcha_title),
            subtitle: Text(context.l10n.hcaptcha_subtitle),
            secondary: Icon(
              Icons.accessible_forward,
              color: enabled ? theme.colorScheme.primary : null,
            ),
            value: enabled,
            onChanged: (value) => _service.setEnabled(value),
          ),
          if (enabled) ...[
            Divider(
              height: 1,
              color:
                  theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
            ),
            // Cookie 状态行
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Icon(
                    hasCookie
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    size: 16,
                    color: hasCookie
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    hasCookie
                        ? context.l10n.hcaptcha_cookieSet
                        : context.l10n.hcaptcha_cookieNotSet,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: hasCookie
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: hasCookie ? FontWeight.w500 : null,
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color:
                  theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
            ),
            // 操作按钮行
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              child: Row(
                children: [
                  _ActionButton(
                    icon: Icons.open_in_browser,
                    label: context.l10n.hcaptcha_webviewGet,
                    onPressed: () => _openWebView(context),
                  ),
                  const SizedBox(width: 8),
                  _ActionButton(
                    icon: Icons.content_paste,
                    label: context.l10n.hcaptcha_pasteCookie,
                    onPressed: () => _pasteCookie(context),
                  ),
                  if (hasCookie) ...[
                    const SizedBox(width: 8),
                    _ActionButton(
                      icon: Icons.delete_outline,
                      label: context.l10n.hcaptcha_clear,
                      onPressed: () => _clearCookie(context),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openWebView(BuildContext context) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const HCaptchaAccessibilityPage(),
      ),
    );
  }

  Future<void> _pasteCookie(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.hcaptcha_pasteDialogTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.hcaptcha_pasteDialogDesc,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: context.l10n.hcaptcha_pasteDialogHint,
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result != null && result.isNotEmpty) {
      await HCaptchaAccessibilityService().setCookie(result);
      ToastService.showSuccess(S.current.hcaptcha_cookieSaved);
    }
  }

  Future<void> _clearCookie(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(context.l10n.hcaptcha_clearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await HCaptchaAccessibilityService().clearCookie();
      ToastService.showSuccess(S.current.hcaptcha_cookieCleared);
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
