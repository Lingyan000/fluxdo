import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import '../../pages/appearance_page.dart';
import '../../pages/bottom_nav_settings_page.dart';
import '../../pages/data_management_page.dart';
import '../../pages/network_settings_page/network_settings_page.dart';
import '../../pages/preferences_page.dart';
import '../../pages/reading_settings_page.dart';
import '../../pages/shortcut_settings_page.dart';
import '../../utils/platform_utils.dart';
import '../definitions/appearance_defs.dart';
import '../definitions/bottom_nav_defs.dart';
import '../definitions/data_management_defs.dart';
import '../definitions/network_defs.dart';
import '../definitions/preferences_defs.dart';
import '../definitions/reading_defs.dart';
import '../definitions/shortcut_defs.dart';
import '../settings_model.dart';
import '../../theme/app_colors.dart';

/// 搜索结果项
class SettingsSearchResult {
  final SettingsModel model;
  final String categoryName;
  final IconData categoryIcon;
  final Color categoryColor;

  /// 构建目标页面，支持高亮定位
  final Widget Function({String? highlightId}) pageBuilder;

  const SettingsSearchResult({
    required this.model,
    required this.categoryName,
    required this.categoryIcon,
    required this.categoryColor,
    required this.pageBuilder,
  });
}

/// 构建全局搜索索引
List<SettingsSearchResult> buildSearchIndex(BuildContext context) {
  final l10n = context.l10n;

  List<SettingsSearchResult> fromGroups(
    List<SettingsGroup> groups, {
    required String categoryName,
    required IconData categoryIcon,
    required Color categoryColor,
    required Widget Function({String? highlightId}) pageBuilder,
  }) {
    return groups
        .expand((g) => g.items)
        .where((item) {
          if (item is PlatformConditionalModel) return item.shouldShow;
          return true;
        })
        .map((item) => SettingsSearchResult(
              model: item is PlatformConditionalModel ? item.inner : item,
              categoryName: categoryName,
              categoryIcon: categoryIcon,
              categoryColor: categoryColor,
              pageBuilder: pageBuilder,
            ))
        .toList();
  }

  return [
    ...fromGroups(
      buildReadingGroups(context),
      categoryName: l10n.settings_reading,
      categoryIcon: Symbols.auto_stories_rounded,
      categoryColor: context.appColors.deepOrange,
      pageBuilder: ({highlightId}) =>
          ReadingSettingsPage(highlightId: highlightId),
    ),
    ...fromGroups(
      buildPreferencesGroups(context),
      categoryName: l10n.settings_preferences,
      categoryIcon: Symbols.tune_rounded,
      categoryColor: context.appColors.deepPurple,
      pageBuilder: ({highlightId}) =>
          PreferencesPage(highlightId: highlightId),
    ),
    ...fromGroups(
      buildBottomNavGroups(context),
      categoryName: l10n.settings_bottomNav,
      categoryIcon: Symbols.view_day_rounded,
      categoryColor: context.appColors.amber,
      pageBuilder: ({highlightId}) =>
          BottomNavSettingsPage(highlightId: highlightId),
    ),
    ...fromGroups(
      buildAppearanceGroups(context),
      categoryName: l10n.settings_appearance,
      categoryIcon: Symbols.color_lens_rounded,
      categoryColor: context.appColors.teal,
      pageBuilder: ({highlightId}) =>
          AppearancePage(highlightId: highlightId),
    ),
    ...fromGroups(
      buildNetworkGroups(context),
      categoryName: l10n.settings_network,
      categoryIcon: Symbols.network_check_rounded,
      categoryColor: context.appColors.blueGrey,
      pageBuilder: ({highlightId}) =>
          NetworkSettingsPage(highlightId: highlightId),
    ),
    ...fromGroups(
      buildDataManagementGroups(context),
      categoryName: l10n.settings_dataManagement,
      categoryIcon: Symbols.storage_rounded,
      categoryColor: context.appColors.brown,
      pageBuilder: ({highlightId}) =>
          DataManagementPage(highlightId: highlightId),
    ),
    // 快捷键（仅桌面端）
    if (PlatformUtils.isDesktop)
      ...fromGroups(
        buildShortcutGroups(context),
        categoryName: l10n.settings_shortcuts,
        categoryIcon: Symbols.keyboard_rounded,
        categoryColor: context.appColors.cyan,
        pageBuilder: ({highlightId}) =>
            ShortcutSettingsPage(highlightId: highlightId),
      ),
  ];
}
