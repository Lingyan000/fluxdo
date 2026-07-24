import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../settings/search/settings_search_index.dart';
import '../utils/platform_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'about_page.dart';
import 'appearance_page.dart';
import 'bottom_nav_settings_page.dart';
import 'data_management_page.dart';
import 'network_settings_page/network_settings_page.dart';
import 'notion_settings_page.dart';
import 'preferences_page.dart';
import 'reading_settings_page.dart';
import 'shortcut_settings_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  late final ShortcutSurfaceBinding _shortcutSurfaceBinding =
      ShortcutSurfaceBinding(
        ref: ref,
        id: ShortcutSurfaceIds.settings,
        triggerAction: ShortcutAction.openSettings,
        kind: ShortcutSurfaceKind.route,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.reveal,
        passthroughActions: ShortcutSurfaceActionSets.globalRoutePassthrough,
      );
  ModalRoute<dynamic>? _route;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    _route = route;
    _shortcutSurfaceBinding.registerDeferred(
      context,
      onClose: () => Navigator.of(context).maybePop(),
      onFocus: _revealSelf,
    );
  }

  void _revealSelf() {
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || route.isCurrent) return;
    navigator.popUntil((candidate) => identical(candidate, route));
  }

  @override
  void dispose() {
    _shortcutSurfaceBinding.disposeDeferred();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isSearching = _query.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings_title)),
      body: Column(
        children: [
          // 搜索栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchController,
              focusNode: _focusNode,
              onChanged: (value) => setState(() => _query = value.trim()),
              decoration: InputDecoration(
                hintText: l10n.settings_searchHint,
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Symbols.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                          _focusNode.unfocus();
                        },
                      )
                    : null,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                isDense: true,
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          // 内容区域
          Expanded(
            child: isSearching
                ? _buildSearchResults(theme)
                : _buildCategoryList(theme, l10n),
          ),
        ],
      ),
    );
  }

  /// 搜索结果（自动从数据声明派生）
  Widget _buildSearchResults(ThemeData theme) {
    final allResults = buildSearchIndex(context);
    final q = _query.toLowerCase();
    final filtered = allResults.where((r) => r.model.matchesQuery(q)).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.search_off_rounded,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.settings_searchEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: 3),
      itemBuilder: (context, index) {
        final result = filtered[index];
        return SegmentedCardItem(
          index: index,
          count: filtered.length,
          child: ListTile(
            leading: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: result.categoryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                result.categoryIcon,
                color: result.categoryColor,
                size: 18,
              ),
            ),
            title: Text(
              result.model.title,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              result.categoryName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
            trailing: Icon(
              Symbols.chevron_right_rounded,
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
              size: 18,
            ),
            dense: true,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    result.pageBuilder(highlightId: result.model.id),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 默认分类列表
  Widget _buildCategoryList(ThemeData theme, AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      children: [
        SegmentedCardGroup(
          children: [
            _buildOptionTile(
              icon: Symbols.color_lens_rounded,
              iconColor: Colors.teal,
              title: l10n.settings_appearance,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AppearancePage()),
              ),
            ),
            _buildOptionTile(
              icon: Symbols.auto_stories_rounded,
              iconColor: Colors.deepOrange,
              title: l10n.settings_reading,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ReadingSettingsPage(),
                ),
              ),
            ),
            _buildOptionTile(
              icon: Symbols.network_check_rounded,
              iconColor: Colors.blueGrey,
              title: l10n.settings_network,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NetworkSettingsPage(),
                ),
              ),
            ),
            _buildOptionTile(
              icon: Symbols.tune_rounded,
              iconColor: Colors.deepPurple,
              title: l10n.settings_preferences,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PreferencesPage()),
              ),
            ),
            _buildOptionTile(
              icon: Symbols.view_day_rounded,
              iconColor: Colors.amber,
              title: l10n.settings_bottomNav,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BottomNavSettingsPage(),
                ),
              ),
            ),
            _buildOptionTile(
              icon: Symbols.storage_rounded,
              iconColor: Colors.brown,
              title: l10n.settings_dataManagement,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DataManagementPage()),
              ),
            ),
            _buildOptionTile(
              icon: Symbols.cloud_sync_rounded,
              iconColor: Colors.deepPurple,
              title: l10n.notion_title,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NotionSettingsPage(),
                ),
              ),
            ),
            // 快捷键（仅桌面端）
            if (PlatformUtils.isDesktop)
              _buildOptionTile(
                icon: Symbols.keyboard_rounded,
                iconColor: Colors.cyan,
                title: l10n.settings_shortcuts,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ShortcutSettingsPage(),
                  ),
                ),
              ),
            _buildOptionTile(
              icon: Symbols.info_rounded,
              iconColor: Colors.indigo,
              title: l10n.settings_about,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    Color? iconColor,
    required String title,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final finalIconColor = iconColor ?? theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: finalIconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: finalIconColor, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Symbols.chevron_right_rounded,
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
