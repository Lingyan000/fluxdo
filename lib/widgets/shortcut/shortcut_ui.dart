import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/shortcut_binding.dart';

String shortcutCategoryLabel(
  ShortcutCategory category,
  AppLocalizations l10n,
) {
  return switch (category) {
    ShortcutCategory.navigation => l10n.shortcuts_navigation,
    ShortcutCategory.content => l10n.shortcuts_content,
    ShortcutCategory.topic => l10n.shortcuts_topic,
    ShortcutCategory.post => l10n.shortcuts_post,
  };
}

String shortcutActionLabel(ShortcutAction action, AppLocalizations l10n) {
  return switch (action) {
    ShortcutAction.navigateBack => l10n.shortcuts_navigateBack,
    ShortcutAction.navigateBackAlt => l10n.shortcuts_navigateBackAlt,
    ShortcutAction.openSearch => l10n.shortcuts_openSearch,
    ShortcutAction.closeOverlay => l10n.shortcuts_closeOverlay,
    ShortcutAction.openSettings => l10n.shortcuts_openSettings,
    ShortcutAction.refresh => l10n.shortcuts_refresh,
    ShortcutAction.showShortcutHelp => l10n.shortcuts_showHelp,
    ShortcutAction.nextItem => l10n.shortcuts_nextItem,
    ShortcutAction.previousItem => l10n.shortcuts_previousItem,
    ShortcutAction.openItem => l10n.shortcuts_openItem,
    ShortcutAction.switchPane => l10n.shortcuts_switchPane,
    ShortcutAction.toggleNotifications => l10n.shortcuts_toggleNotifications,
    ShortcutAction.switchToTopics => l10n.shortcuts_switchToTopics,
    ShortcutAction.switchToProfile => l10n.shortcuts_switchToProfile,
    ShortcutAction.createTopic => l10n.shortcuts_createTopic,
    ShortcutAction.previousTab => l10n.shortcuts_previousTab,
    ShortcutAction.nextTab => l10n.shortcuts_nextTab,
    ShortcutAction.toggleAiPanel => l10n.shortcuts_toggleAiPanel,
    ShortcutAction.jumpToPost => l10n.shortcuts_jumpToPost,
    ShortcutAction.goToUnreadPost => l10n.shortcuts_goToUnreadPost,
    ShortcutAction.replyTopic => l10n.shortcuts_replyTopic,
    ShortcutAction.shareTopic => l10n.shortcuts_shareTopic,
    ShortcutAction.bookmarkTopic => l10n.shortcuts_bookmarkTopic,
    ShortcutAction.replyPost => l10n.shortcuts_replyPost,
    ShortcutAction.quotePost => l10n.shortcuts_quotePost,
    ShortcutAction.likePost => l10n.shortcuts_likePost,
    ShortcutAction.sharePost => l10n.shortcuts_sharePost,
    ShortcutAction.bookmarkPost => l10n.shortcuts_bookmarkPost,
    ShortcutAction.editPost => l10n.shortcuts_editPost,
    ShortcutAction.flagPost => l10n.shortcuts_flagPost,
    ShortcutAction.deletePost => l10n.shortcuts_deletePost,
  };
}

class ShortcutActivatorCaps extends StatelessWidget {
  final SingleActivator activator;
  final WrapAlignment alignment;
  final double spacing;
  final double runSpacing;
  final double minKeyWidth;
  final double fontSize;
  final EdgeInsetsGeometry keyPadding;

  const ShortcutActivatorCaps({
    super.key,
    required this.activator,
    this.alignment = WrapAlignment.end,
    this.spacing = 4,
    this.runSpacing = 4,
    this.minKeyWidth = 28,
    this.fontSize = 12,
    this.keyPadding = const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
  });

  @override
  Widget build(BuildContext context) {
    final parts = ShortcutBinding.formatActivatorParts(activator);

    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      children: [
        for (final part in parts)
          ShortcutKeyCap(
            label: part,
            minWidth: minKeyWidth,
            fontSize: fontSize,
            padding: keyPadding,
          ),
      ],
    );
  }
}

class ShortcutKeyCap extends StatelessWidget {
  final String label;
  final double minWidth;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const ShortcutKeyCap({
    super.key,
    required this.label,
    this.minWidth = 28,
    this.fontSize = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(7);
    final textColor = theme.brightness == Brightness.dark
        ? const Color(0xFFF5F5F5)
        : const Color(0xFF1F2328);

    return Container(
      constraints: BoxConstraints(minWidth: minWidth),
      padding: padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
        borderRadius: borderRadius,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.75),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.04),
            blurRadius: 1,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.72),
            width: 1.7,
          ),
        ),
      ),
      child: Text(
        label.isEmpty ? '?' : label,
        textAlign: TextAlign.center,
        style: (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
          color: textColor,
          fontWeight: FontWeight.w600,
          fontSize: fontSize,
          height: 1.1,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
