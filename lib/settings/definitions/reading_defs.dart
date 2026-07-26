import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../pages/topic_detail_page/widgets/progress_gesture_action_meta.dart';
import '../../pages/topic_detail_page/widgets/progress_gesture_menu_settings_page.dart';
import '../../providers/preferences_provider.dart';
import '../../services/preloaded_data_service.dart';
import '../settings_model.dart';

/// 阅读设置数据声明
List<SettingsGroup> buildReadingGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    SettingsGroup(
      title: l10n.appearance_reading,
      icon: Symbols.chrome_reader_mode_rounded,
      items: [
        DoubleSliderModel(
          id: 'contentFontScale',
          title: l10n.appearance_contentFontSize,
          icon: Symbols.format_size_rounded,
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
          icon: Symbols.auto_fix_high_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).displayPanguSpacing,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setDisplayPanguSpacing(v),
        ),
        SwitchModel(
          id: 'boostDanmaku',
          title: l10n.reading_boostDanmaku,
          subtitle: l10n.reading_boostDanmakuDesc,
          icon: Symbols.rocket_launch_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).boostDanmaku,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setBoostDanmaku(v),
        ),
        SwitchModel(
          id: 'showSuggestedTopics',
          title: l10n.reading_showSuggestedTopics,
          subtitle: l10n.reading_showSuggestedTopicsDesc,
          icon: Symbols.forum_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).showSuggestedTopics,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setShowSuggestedTopics(v),
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.preferences_basic,
      icon: Symbols.touch_app_rounded,
      items: [
        SwitchModel(
          id: 'longPressPreview',
          title: l10n.preferences_longPressPreview,
          subtitle: l10n.preferences_longPressPreviewDesc,
          icon: Symbols.touch_app_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).longPressPreview,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setLongPressPreview(v),
        ),
        SwitchModel(
          id: 'hideBarOnScroll',
          title: l10n.preferences_hideBarOnScroll,
          subtitle: l10n.preferences_hideBarOnScrollDesc,
          icon: Symbols.swap_vert_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).hideBarOnScroll,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setHideBarOnScroll(v),
        ),
        SwitchModel(
          id: 'openExternalLinksInAppBrowser',
          title: l10n.preferences_openLinksInApp,
          subtitle: l10n.preferences_openLinksInAppDesc,
          icon: Symbols.open_in_browser_rounded,
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
          icon: Symbols.link_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).expandRelatedLinks,
          onChanged: (ref, v) =>
              ref.read(preferencesProvider.notifier).setExpandRelatedLinks(v),
        ),
        // 服务端未启用签名插件时隐藏该开关
        if (PreloadedDataService().signaturesEnabled)
          SwitchModel(
            id: 'showSignatures',
            title: l10n.reading_showSignatures,
            subtitle: l10n.reading_showSignaturesDesc,
            icon: Symbols.draw_rounded,
            getValue: (ref) => ref.watch(preferencesProvider).showSignatures,
            onChanged: (ref, v) =>
                ref.read(preferencesProvider.notifier).setShowSignatures(v),
          ),
        if (PreloadedDataService().signaturesEnabled)
          SwitchModel(
            id: 'adaptiveSignatureFrameRate',
            title: l10n.reading_adaptiveSignatureFrameRate,
            subtitle: l10n.reading_adaptiveSignatureFrameRateDesc,
            icon: Symbols.speed_rounded,
            getValue: (ref) =>
                ref.watch(preferencesProvider).adaptiveSignatureFrameRate,
            onChanged: (ref, v) => ref
                .read(preferencesProvider.notifier)
                .setAdaptiveSignatureFrameRate(v),
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
                Symbols.tab_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(l.reading_bookmarksOpenMode),
              subtitle: Text(switch (currentMode) {
                BookmarksOpenMode.defaultRoute =>
                  l.reading_bookmarksOpenModeDefault,
                BookmarksOpenMode.tabbedWorkspace =>
                  l.reading_bookmarksOpenModeTabbedWorkspace,
              }),
              trailing: const Icon(Symbols.chevron_right_rounded),
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
            icon: Symbols.swipe_left_rounded,
            getValue: (ref) => ref.watch(preferencesProvider).aiSwipeEntry,
            onChanged: (ref, v) =>
                ref.read(preferencesProvider.notifier).setAiSwipeEntry(v),
          ),
          condition: () => Platform.isIOS || Platform.isAndroid,
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.progressGesture_title,
      icon: Symbols.gesture_rounded,
      items: [
        SwitchModel(
          id: 'progressGesturesEnabled',
          title: l10n.progressGesture_enable,
          subtitle: l10n.progressGesture_enableDesc,
          icon: Symbols.swipe_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).progressGesturesEnabled,
          onChanged: (ref, v) => ref
              .read(preferencesProvider.notifier)
              .setProgressGesturesEnabled(v),
        ),
        CustomModel(
          id: 'progressGestureSwipeLeft',
          title: l10n.progressGesture_swipeLeft,
          builder: (context, ref) {
            final enabled = ref.watch(
              preferencesProvider.select((p) => p.progressGesturesEnabled),
            );
            final current = ref.watch(
              preferencesProvider.select((p) => p.progressGestureSwipeLeft),
            );
            final meta = progressGestureActionMeta(context, current);
            return ListTile(
              enabled: enabled,
              leading: Icon(
                Symbols.swipe_left_rounded,
                color: enabled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).disabledColor,
              ),
              title: Text(context.l10n.progressGesture_swipeLeft),
              subtitle: Text(meta.label),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: enabled
                  ? () => _showGestureActionPicker(
                      context,
                      ref,
                      current,
                      (a) => ref
                          .read(preferencesProvider.notifier)
                          .setProgressGestureSwipeLeft(a),
                    )
                  : null,
            );
          },
        ),
        CustomModel(
          id: 'progressGestureSwipeRight',
          title: l10n.progressGesture_swipeRight,
          builder: (context, ref) {
            final enabled = ref.watch(
              preferencesProvider.select((p) => p.progressGesturesEnabled),
            );
            final current = ref.watch(
              preferencesProvider.select((p) => p.progressGestureSwipeRight),
            );
            final meta = progressGestureActionMeta(context, current);
            return ListTile(
              enabled: enabled,
              leading: Icon(
                Symbols.swipe_right_rounded,
                color: enabled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).disabledColor,
              ),
              title: Text(context.l10n.progressGesture_swipeRight),
              subtitle: Text(meta.label),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: enabled
                  ? () => _showGestureActionPicker(
                      context,
                      ref,
                      current,
                      (a) => ref
                          .read(preferencesProvider.notifier)
                          .setProgressGestureSwipeRight(a),
                    )
                  : null,
            );
          },
        ),
        CustomModel(
          id: 'progressGestureSwipeUp',
          title: l10n.progressGesture_swipeUp,
          builder: (context, ref) {
            final enabled = ref.watch(
              preferencesProvider.select((p) => p.progressGesturesEnabled),
            );
            final current = ref.watch(
              preferencesProvider.select((p) => p.progressGestureSwipeUp),
            );
            final meta = progressGestureActionMeta(context, current);
            return ListTile(
              enabled: enabled,
              leading: Icon(
                Symbols.swipe_up_rounded,
                color: enabled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).disabledColor,
              ),
              title: Text(context.l10n.progressGesture_swipeUp),
              subtitle: Text(meta.label),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: enabled
                  ? () => _showGestureActionPicker(
                      context,
                      ref,
                      current,
                      (a) => ref
                          .read(preferencesProvider.notifier)
                          .setProgressGestureSwipeUp(a),
                    )
                  : null,
            );
          },
        ),
        CustomModel(
          id: 'progressGestureMenuActions',
          title: l10n.progressGesture_longPressMenu,
          subtitle: l10n.progressGesture_longPressMenuDesc,
          builder: (context, ref) {
            final enabled = ref.watch(
              preferencesProvider.select((p) => p.progressGesturesEnabled),
            );
            final items = ref.watch(
              preferencesProvider.select((p) => p.progressGestureMenuActions),
            );
            return ListTile(
              enabled: enabled,
              leading: Icon(
                Symbols.fingerprint_rounded,
                color: enabled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).disabledColor,
              ),
              title: Text(context.l10n.progressGesture_longPressMenu),
              subtitle: Text(
                '${items.length}/$kProgressGestureMenuMax · '
                '${items.map((a) => progressGestureActionMeta(context, a).label).join(' · ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Symbols.chevron_right_rounded),
              onTap: enabled
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ProgressGestureMenuSettingsPage(),
                      ),
                    )
                  : null,
            );
          },
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.nested_title,
      icon: Symbols.account_tree_rounded,
      items: [
        SwitchModel(
          id: 'defaultNestedView',
          title: l10n.nested_defaultView,
          subtitle: l10n.nested_defaultViewDesc,
          icon: Symbols.account_tree_rounded,
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
                Symbols.linear_scale_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(l.nested_lineStyle),
              subtitle: Text(switch (currentStyle) {
                NestedLineStyle.auto => l.nested_lineStyleAuto,
                NestedLineStyle.lLine => l.nested_lineStyleL,
                NestedLineStyle.straight => l.nested_lineStyleStraight,
              }),
              trailing: const Icon(Symbols.chevron_right_rounded),
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
                      ? Symbols.radio_button_checked_rounded
                      : Symbols.radio_button_unchecked_rounded,
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
                      ? Symbols.radio_button_checked_rounded
                      : Symbols.radio_button_unchecked_rounded,
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

void _showGestureActionPicker(
  BuildContext context,
  WidgetRef ref,
  ProgressGestureAction current,
  void Function(ProgressGestureAction) onPicked,
) {
  final l10n = context.l10n;
  showDialog<ProgressGestureAction>(
    context: context,
    builder: (dialogContext) {
      final screen = MediaQuery.of(dialogContext).size;
      // 桌面端拉宽到 560，移动端贴近全宽；自动按列宽切换 1/2/3 列
      final dialogWidth = math.min(screen.width - 48, 560.0);
      final dialogMaxHeight = math.min(screen.height * 0.85, 640.0);
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 24,
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogWidth,
            maxHeight: dialogMaxHeight,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Text(
                  l10n.progressGesture_pickAction,
                  style: Theme.of(dialogContext).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Flexible(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  shrinkWrap: true,
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 240,
                        mainAxisExtent: 52,
                        crossAxisSpacing: 4,
                        mainAxisSpacing: 4,
                      ),
                  itemCount: ProgressGestureAction.values.length,
                  itemBuilder: (context, index) {
                    final action = ProgressGestureAction.values[index];
                    final meta = progressGestureActionMeta(context, action);
                    final isCurrent = action == current;
                    final theme = Theme.of(context);
                    return InkWell(
                      onTap: () => Navigator.pop(dialogContext, action),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isCurrent
                                  ? Symbols.radio_button_checked_rounded
                                  : Symbols.radio_button_unchecked_rounded,
                              color: isCurrent
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              meta.icon,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                meta.label,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: isCurrent
                                      ? theme.colorScheme.primary
                                      : null,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(l10n.common_cancel),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  ).then((selected) {
    if (selected != null) onPicked(selected);
  });
}
