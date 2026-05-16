import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/preferences_provider.dart';
import '../settings_model.dart';

/// 阅读设置数据声明
List<SettingsGroup> buildReadingGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    SettingsGroup(
      title: l10n.appearance_reading,
      icon: Icons.chrome_reader_mode_outlined,
      items: [
        DoubleSliderModel(
          id: 'contentFontScale',
          title: l10n.appearance_contentFontSize,
          icon: Icons.format_size_rounded,
          min: 0.8,
          max: 1.4,
          divisions: 12,
          labelBuilder: (v) => '${(v * 100).round()}%',
          getValue: (ref) => ref.watch(preferencesProvider).contentFontScale,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setContentFontScale(v),
          onReset: (ref) =>
              ref.read(preferencesProvider.notifier).setContentFontScale(1.0),
        ),
        SwitchModel(
          id: 'displayPanguSpacing',
          title: l10n.appearance_panguSpacing,
          subtitle: l10n.appearance_panguSpacingDesc,
          icon: Icons.auto_fix_high_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).displayPanguSpacing,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setDisplayPanguSpacing(v),
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.preferences_basic,
      icon: Icons.touch_app_outlined,
      items: [
        SwitchModel(
          id: 'longPressPreview',
          title: l10n.preferences_longPressPreview,
          subtitle: l10n.preferences_longPressPreviewDesc,
          icon: Icons.touch_app_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).longPressPreview,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setLongPressPreview(v),
        ),
        SwitchModel(
          id: 'hideBarOnScroll',
          title: l10n.preferences_hideBarOnScroll,
          subtitle: l10n.preferences_hideBarOnScrollDesc,
          icon: Icons.swap_vert_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).hideBarOnScroll,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setHideBarOnScroll(v),
        ),
        SwitchModel(
          id: 'openExternalLinksInAppBrowser',
          title: l10n.preferences_openLinksInApp,
          subtitle: l10n.preferences_openLinksInAppDesc,
          icon: Icons.open_in_browser_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).openExternalLinksInAppBrowser,
          onChanged: (ref, v) => ref
              .read(preferencesProvider.notifier)
              .setOpenExternalLinksInAppBrowser(v),
        ),
        SwitchModel(
          id: 'expandRelatedLinks',
          title: l10n.reading_expandRelatedLinks,
          subtitle: l10n.reading_expandRelatedLinksDesc,
          icon: Icons.link_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).expandRelatedLinks,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setExpandRelatedLinks(v),
        ),
        SwitchModel(
          id: 'showSignatures',
          title: l10n.reading_showSignatures,
          subtitle: l10n.reading_showSignaturesDesc,
          icon: Icons.draw_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).showSignatures,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setShowSignatures(v),
        ),
        CustomModel(
          id: 'bookmarksOpenMode',
          title: l10n.reading_bookmarksOpenMode,
          builder: (context, ref) {
            final currentMode = ref
                .watch(preferencesProvider)
                .bookmarksOpenMode;
            final l = context.l10n;
            return ListTile(
              leading: Icon(
                Icons.tab_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(l.reading_bookmarksOpenMode),
              subtitle: Text(switch (currentMode) {
                BookmarksOpenMode.defaultRoute =>
                  l.reading_bookmarksOpenModeDefault,
                BookmarksOpenMode.tabbedWorkspace =>
                  l.reading_bookmarksOpenModeTabbedWorkspace,
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  _showBookmarksOpenModePicker(context, ref, currentMode),
            );
          },
        ),
        PlatformConditionalModel(
          inner: SwitchModel(
            id: 'aiSwipeEntry',
            title: l10n.reading_aiSwipeEntry,
            subtitle: l10n.reading_aiSwipeEntryDesc,
            icon: Icons.swipe_left_rounded,
            getValue: (ref) => ref.watch(preferencesProvider).aiSwipeEntry,
            onChanged: (ref, v) =>
                ref.read(preferencesProvider.notifier).setAiSwipeEntry(v),
          ),
          condition: () => Platform.isIOS || Platform.isAndroid,
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.nested_title,
      icon: Icons.account_tree_outlined,
      items: [
        SwitchModel(
          id: 'defaultNestedView',
          title: l10n.nested_defaultView,
          subtitle: l10n.nested_defaultViewDesc,
          icon: Icons.account_tree_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).defaultNestedView,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setDefaultNestedView(v),
        ),
        CustomModel(
          id: 'nestedLineStyle',
          title: l10n.nested_lineStyle,
          builder: (context, ref) {
            final currentStyle = ref.watch(preferencesProvider).nestedLineStyle;
            final l = context.l10n;
            return ListTile(
              leading: Icon(
                Icons.linear_scale_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(l.nested_lineStyle),
              subtitle: Text(switch (currentStyle) {
                NestedLineStyle.auto => l.nested_lineStyleAuto,
                NestedLineStyle.lLine => l.nested_lineStyleL,
                NestedLineStyle.straight => l.nested_lineStyleStraight,
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showLineStylePicker(context, ref, currentStyle),
            );
          },
        ),
      ],
    ),
  ];
}

void _showLineStylePicker(
  BuildContext context,
  WidgetRef ref,
  NestedLineStyle current,
) {
  final l10n = context.l10n;
  final options = [
    (NestedLineStyle.auto, l10n.nested_lineStyleAuto),
    (NestedLineStyle.lLine, l10n.nested_lineStyleL),
    (NestedLineStyle.straight, l10n.nested_lineStyleStraight),
  ];

  showDialog<NestedLineStyle>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l10n.nested_lineStyle),
      children: [
        for (final (style, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, style),
            child: Row(
              children: [
                Icon(
                  style == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: style == current
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          ),
      ],
    ),
  ).then((selected) {
    if (selected != null) {
      ref.read(preferencesProvider.notifier).setNestedLineStyle(selected);
    }
  });
}

void _showBookmarksOpenModePicker(
  BuildContext context,
  WidgetRef ref,
  BookmarksOpenMode current,
) {
  final l10n = context.l10n;
  final options = [
    (BookmarksOpenMode.defaultRoute, l10n.reading_bookmarksOpenModeDefault),
    (
      BookmarksOpenMode.tabbedWorkspace,
      l10n.reading_bookmarksOpenModeTabbedWorkspace,
    ),
  ];

  showDialog<BookmarksOpenMode>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l10n.reading_bookmarksOpenMode),
      children: [
        for (final (mode, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, mode),
            child: Row(
              children: [
                Icon(
                  mode == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: mode == current
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          ),
      ],
    ),
  ).then((selected) {
    if (selected != null) {
      ref.read(preferencesProvider.notifier).setBookmarksOpenMode(selected);
    }
  });
}
