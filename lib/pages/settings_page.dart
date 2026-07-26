import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../settings/search/settings_search_index.dart';
import '../utils/platform_utils.dart';
import '../widgets/layout/auto_restore_master_detail_route.dart';
import '../widgets/layout/master_detail_layout.dart';
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
  static const double parallelMasterWidth = 380;
  static const double parallelMinDetailWidth = 480;

  /// 平行视界嵌入模式：AppBar 用 [onEmbeddedBack] 关闭当前层，而不是
  /// Navigator pop（嵌入面板不在 Navigator 路由栈里）。页面自身宽度
  /// 足够时，子设置页会进入右侧的独立 Navigator；窄屏仍全屏 push。
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  const SettingsPage({
    super.key,
    this.embeddedMode = false,
    this.onEmbeddedBack,
  });

  @visibleForTesting
  static bool canShowParallelFor(BuildContext context) {
    return MasterDetailLayout.canShowBothPanesFor(
      context,
      masterWidth: parallelMasterWidth,
      minDetailWidth: parallelMinDetailWidth,
    );
  }

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

/// 观察设置页 detail 内嵌 Navigator:pop 回空态路由时通知宿主清迁移凭据。
class _DetailPopObserver extends NavigatorObserver {
  _DetailPopObserver({required this.onEmptied});

  final VoidCallback onEmptied;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.settings.name == 'settings-detail-empty') {
      onEmptied();
    }
  }
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _detailNavigatorKey = GlobalKey<NavigatorState>();
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

  /// detail 侧栏当前打开的一级子设置页(宽窄迁移的凭据)。
  ///
  /// detail 是内嵌 Navigator,之前窗口变窄时整个导航栈直接被丢弃 ——
  /// 折叠屏"折起来"就等于内容凭空消失。记录 builder 后:变窄转成一次
  /// 全屏 push(AutoRestore 包裹),展开时自动收回并重新推进 detail;
  /// 折来折去每一轮都走同一套往返。二级以深的内部路由不保(通用机制
  /// 拿不到),迁移保住一级页已覆盖绝大多数场景。
  WidgetBuilder? _detailBuilder;
  bool _detailMigrating = false;

  /// detail 内嵌 Navigator 回到空态(ESC/返回收起)时清掉迁移凭据,
  /// 否则窄下来会把早已关掉的页面又弹出来。
  late final _DetailPopObserver _detailPopObserver = _DetailPopObserver(
    onEmptied: () => _detailBuilder = null,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) return;
    _route = route;
    _shortcutSurfaceBinding.registerDeferred(
      context,
      onClose: _handleEscClose,
      onFocus: _revealSelf,
    );
  }

  /// ESC 关闭：平行视界模式下 detail 侧栏有独立 Navigator,先尝试收起它
  /// (回到"请选择"占位态),detail 已经空了或不在平行视界模式再退外层。
  /// 之前直接 Navigator.of(context).maybePop() 拿到的是宿主(外层)导航
  /// 栈,与 detail 内部导航栈是两回事——平行视界下按 ESC 会"不生效"
  /// (外层 maybePop 返回 false 却什么可见变化都没有),真机复现。
  void _handleEscClose() {
    final detailNavigator = _detailNavigatorKey.currentState;
    if (detailNavigator != null && detailNavigator.canPop()) {
      detailNavigator.popUntil((route) => route.isFirst);
      return;
    }
    Navigator.of(context).maybePop();
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

    final master = _buildSettingsScaffold(theme, l10n, isSearching);
    final canShowParallel = SettingsPage.canShowParallelFor(context);
    if (!canShowParallel) {
      _maybeMigrateDetailToFullScreen();
      return master;
    }

    return MasterDetailLayout(
      masterWidth: SettingsPage.parallelMasterWidth,
      minDetailWidth: SettingsPage.parallelMinDetailWidth,
      minMasterRatio: 0.28,
      maxMasterRatio: 0.48,
      preferredMasterRatio: 0.34,
      master: master,
      detail: Navigator(
        key: _detailNavigatorKey,
        observers: [_detailPopObserver],
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: const RouteSettings(name: 'settings-detail-empty'),
          builder: (_) => _buildDetailEmptyState(theme),
        ),
      ),
    );
  }

  void _maybeMigrateDetailToFullScreen() {
    // 嵌入模式(设置页本身在别人的右栏里)不自行迁移:宿主面板的迁移
    // 会连同整个嵌入设置页一起转全屏,这里再推一层就双开了。
    if (widget.embeddedMode) return;
    final migrate = _detailBuilder;
    if (migrate == null || _detailMigrating) return;
    final route = _route;
    if (route != null && !route.isCurrent) return;
    _detailMigrating = true;
    _detailBuilder = null; // 所有权交给全屏路由,恢复时经 onRestore 传回
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _detailMigrating = false;
        return;
      }
      // 一帧内又变宽(折叠屏铰链抖动):不推全屏,把子页重推回 detail
      if (SettingsPage.canShowParallelFor(context)) {
        _detailMigrating = false;
        _openSettingsPage(migrate);
        return;
      }
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) => AutoRestoreMasterDetailRoute(
                masterWidth: SettingsPage.parallelMasterWidth,
                minDetailWidth: SettingsPage.parallelMinDetailWidth,
                onRestore: () {
                  // 展开(变宽):路由被自动移除,把子页重新推进 detail 侧栏
                  if (mounted) _openSettingsPage(migrate);
                },
                child: Builder(builder: migrate),
              ),
            ),
          )
          .whenComplete(() {
            if (mounted) _detailMigrating = false;
          });
    });
  }

  Widget _buildSettingsScaffold(
    ThemeData theme,
    AppLocalizations l10n,
    bool isSearching,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_title),
        // embeddedMode 但 onEmbeddedBack 为空（master 面板"上一层预览"，
        // 非当前可交互栈顶）时不能塞 BackButton——BackButton(onPressed:
        // null) 会退化成默认 Navigator.maybePop()，直接捅穿到应用根导航
        // 栈（见 user_profile_page.dart 同类修复的注释）。
        automaticallyImplyLeading: !widget.embeddedMode,
        leading: widget.embeddedMode && widget.onEmbeddedBack != null
            ? BackButton(onPressed: widget.onEmbeddedBack)
            : null,
      ),
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

  Widget _buildDetailEmptyState(ThemeData theme) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.settings_rounded,
              size: 56,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.settings_selectHint,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettingsPage(WidgetBuilder builder) {
    final canShowParallel = SettingsPage.canShowParallelFor(context);
    if (!canShowParallel) {
      Navigator.push(context, MaterialPageRoute(builder: builder));
      return;
    }
    _detailBuilder = builder; // 宽窄迁移凭据(见字段注释)

    void pushIntoDetail() {
      final navigator = _detailNavigatorKey.currentState;
      if (navigator == null) return;
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: builder),
        (route) => route.isFirst,
      );
    }

    if (_detailNavigatorKey.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) pushIntoDetail();
      });
    } else {
      pushIntoDetail();
    }
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
            onTap: () => _openSettingsPage(
              (_) => result.pageBuilder(highlightId: result.model.id),
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
              onTap: () => _openSettingsPage((_) => const AppearancePage()),
            ),
            _buildOptionTile(
              icon: Symbols.auto_stories_rounded,
              iconColor: Colors.deepOrange,
              title: l10n.settings_reading,
              onTap: () =>
                  _openSettingsPage((_) => const ReadingSettingsPage()),
            ),
            _buildOptionTile(
              icon: Symbols.network_check_rounded,
              iconColor: Colors.blueGrey,
              title: l10n.settings_network,
              onTap: () =>
                  _openSettingsPage((_) => const NetworkSettingsPage()),
            ),
            _buildOptionTile(
              icon: Symbols.tune_rounded,
              iconColor: Colors.deepPurple,
              title: l10n.settings_preferences,
              onTap: () => _openSettingsPage((_) => const PreferencesPage()),
            ),
            _buildOptionTile(
              icon: Symbols.view_day_rounded,
              iconColor: Colors.amber,
              title: l10n.settings_bottomNav,
              onTap: () =>
                  _openSettingsPage((_) => const BottomNavSettingsPage()),
            ),
            _buildOptionTile(
              icon: Symbols.storage_rounded,
              iconColor: Colors.brown,
              title: l10n.settings_dataManagement,
              onTap: () => _openSettingsPage((_) => const DataManagementPage()),
            ),
            _buildOptionTile(
              icon: Symbols.cloud_sync_rounded,
              iconColor: Colors.deepPurple,
              title: l10n.notion_title,
              onTap: () => _openSettingsPage((_) => const NotionSettingsPage()),
            ),
            // 快捷键（仅桌面端）
            if (PlatformUtils.isDesktop)
              _buildOptionTile(
                icon: Symbols.keyboard_rounded,
                iconColor: Colors.cyan,
                title: l10n.settings_shortcuts,
                onTap: () =>
                    _openSettingsPage((_) => const ShortcutSettingsPage()),
              ),
            _buildOptionTile(
              icon: Symbols.info_rounded,
              iconColor: Colors.indigo,
              title: l10n.settings_about,
              onTap: () => _openSettingsPage((_) => const AboutPage()),
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
