import 'dart:async';

import '../../services/toast_service.dart';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/shortcut_binding.dart';
import '../../navigation/nav_action_bus.dart';
import '../../providers/core_providers.dart';
import '../../providers/shortcut_provider.dart';
import '../../services/auth_session.dart';
import '../../utils/platform_utils.dart';
import '../../widgets/common/error_view.dart';
import '../../widgets/desktop_refresh_indicator.dart';
import 'mini_app.dart';
import 'mini_app_directory_controller.dart';
import 'mini_app_detail_page.dart';
import 'mini_app_gallery_widgets.dart';
import 'mini_app_launch_shelf.dart';
import 'mini_app_providers.dart';
import 'mini_app_runner_page.dart';
import 'mini_app_window_bridge.dart';

/// Native directory. In the home layer this keeps its search and scroll state
/// while the community sheet covers it; only direct links push a route.
class MiniAppGalleryPage extends ConsumerStatefulWidget {
  const MiniAppGalleryPage({
    super.key,
    this.onClose,
    this.active = true,
    this.activity,
    this.workspace = false,
  });
  final VoidCallback? onClose;
  final bool active;

  /// 优先于 [active]。首页层在下拉显隐时频繁切换，经此传入可避免整页重建。
  final ValueListenable<bool>? activity;
  final bool workspace;
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push<void>(
        InteractionPageRoute(builder: (_) => const MiniAppGalleryPage()),
      );
  @override
  ConsumerState<MiniAppGalleryPage> createState() => _MiniAppGalleryPageState();
}

class _MiniAppGalleryPageState extends ConsumerState<MiniAppGalleryPage> {
  late final MiniAppDirectoryController _directory;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  ShortcutScopeBinding? _shortcuts;
  Timer? _debounce;
  String? _openingAppId;
  bool _showingInfo = false;
  bool _reloadOnActivate = false;
  bool _windowUpdatesPending = false;
  StreamSubscription<String>? _windowUpdates;
  Timer? _windowRefresh;
  final _cards =
      <String, ({MiniApp app, bool opening, bool row, Widget widget})>{};
  List<MiniApp>? _cardApps;

  @override
  void initState() {
    super.initState();
    _directory = MiniAppDirectoryController(
      ref.read(miniAppServiceProvider).directory,
    );
    _wasActive = _active;
    widget.activity?.addListener(_activityChanged);
    if (_active) _directory.refresh();
    AuthSession().generationChanges.addListener(_accountChanged);
    _windowUpdates = MiniAppWindowBridge.updates.stream.listen((_) {
      _windowUpdatesPending = true;
      _windowRefresh?.cancel();
      _windowRefresh = Timer(const Duration(milliseconds: 250), () {
        if (mounted && _active) {
          _windowUpdatesPending = false;
          _directory.refresh();
        }
      });
    });
    _scroll.addListener(_nearEnd);
    if (PlatformUtils.isDesktop) {
      _shortcuts = ShortcutScopeBinding(
        ref: ref,
        scope: ShortcutScope.context,
        enabled: () => mounted && _active,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _shortcuts?.register(context, {
          ShortcutAction.refresh: _refresh,
          ShortcutAction.openSearch: _searchFocus.requestFocus,
          ShortcutAction.closeOverlay: _leaveSearchOrPage,
        });
      });
    }
  }

  Future<void> _refresh() {
    _debounce?.cancel();
    final query = _search.text.trim();
    if (query != _directory.query) return _directory.update(query: query);
    // 相同条件刷新保留现有卡片和滚动位置，避免桌面刷新时整页闪空。
    return _directory.refresh();
  }

  void _leaveSearchOrPage() {
    if (_search.text.isNotEmpty) {
      _search.clear();
      _filter();
      setState(() {});
    } else if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
    } else if (widget.workspace) {
      ref.requestNavDestination(NavEntryIds.home);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Widget _refreshArea({required Widget child}) {
    if (PlatformUtils.isDesktop) {
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: child,
        ),
      );
    }
    return DesktopRefreshIndicator(
      shouldRefresh: () => _active,
      onRefresh: _refresh,
      child: child,
    );
  }

  bool get _active => widget.activity?.value ?? widget.active;
  late bool _wasActive;

  @override
  void didUpdateWidget(MiniAppGalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activity != oldWidget.activity) {
      oldWidget.activity?.removeListener(_activityChanged);
      widget.activity?.addListener(_activityChanged);
    }
    _activityChanged();
  }

  void _activityChanged() {
    final wasActive = _wasActive;
    _wasActive = _active;
    if (_active &&
        !wasActive &&
        (_directory.apps.isEmpty ||
            _reloadOnActivate ||
            _windowUpdatesPending) &&
        !_directory.loading) {
      _windowUpdatesPending = false;
      if (_reloadOnActivate) {
        _reloadOnActivate = false;
        _directory.update(favorites: false, query: _search.text.trim());
      } else {
        _directory.refresh();
      }
    }
  }

  void _accountChanged() {
    _debounce?.cancel();
    if (!_active) {
      _directory.invalidate();
      _reloadOnActivate = true;
      return;
    }
    _directory.update(favorites: false, query: _search.text.trim());
  }

  void _nearEnd() {
    if (_active &&
        _scroll.hasClients &&
        _scroll.position.extentAfter < 400 &&
        _directory.error == null) {
      _directory.loadMore();
    }
  }

  void _queryChanged(String value) {
    _debounce?.cancel();
    _directory.invalidate();
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 350), () => _filter());
  }

  void _filter({String? sort, bool? favorites}) {
    _debounce?.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _directory.update(
      sort: sort,
      query: _search.text.trim(),
      favorites: favorites,
    );
    // 搜索框清除按钮、最近使用区依赖输入内容，不再随目录通知顺带刷新。
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.activity?.removeListener(_activityChanged);
    _windowUpdates?.cancel();
    _windowRefresh?.cancel();
    AuthSession().generationChanges.removeListener(_accountChanged);
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _shortcuts?.disposeDeferred();
    _scroll.dispose();
    _directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(navActionBusProvider, (_, event) {
      if (!widget.workspace ||
          !_active ||
          event?.targetId != NavEntryIds.miniApps) {
        return;
      }
      if (event!.action == NavAction.refresh) {
        _refresh();
      } else if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    });
    ref.listen(currentUserProvider.select((v) => v.value?.id), (
      previous,
      next,
    ) {
      if (previous != next) _accountChanged();
    });
    final l = context.l10n;
    final theme = Theme.of(context);
    final loggedIn = ref.watch(currentUserProvider).value != null;
    final recents = ref.watch(miniAppRecentsProvider);
    final sorts = {
      'latest': l.miniApp_latest,
      'hot': l.miniApp_hot,
      'rating': l.miniApp_rating,
      'used': l.miniApp_used,
    };
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            // 各区只在自己依赖的目录状态变化时重建，翻页加载不波及整页。
            child: Column(
              children: [
                _DirectorySelector(
                  directory: _directory,
                  select: (d) => d.loading,
                  builder: (context) => MiniAppGalleryHeader(
                    onClose: widget.workspace
                        ? null
                        : widget.onClose ?? () => Navigator.maybePop(context),
                    isLayer: !PlatformUtils.isDesktop && widget.onClose != null,
                    onRefresh: PlatformUtils.isDesktop ? _refresh : null,
                    refreshing: _directory.loading,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SearchBar(
                    controller: _search,
                    focusNode: _searchFocus,
                    hintText: l.miniApp_search,
                    leading: const Icon(Symbols.search_rounded),
                    constraints: const BoxConstraints(minHeight: 48),
                    backgroundColor: WidgetStatePropertyAll(
                      theme.colorScheme.surfaceContainerLow,
                    ),
                    elevation: const WidgetStatePropertyAll(0),
                    onChanged: _queryChanged,
                    onSubmitted: (_) {
                      FocusScope.of(context).unfocus();
                      _filter();
                    },
                    trailing: [
                      if (_search.text.isNotEmpty)
                        IconButton(
                          tooltip: l.common_clear,
                          icon: const Icon(Symbols.close_rounded),
                          onPressed: () {
                            _search.clear();
                            _filter();
                          },
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _refreshArea(
                    child: CustomScrollView(
                      controller: _scroll,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        _DirectorySelector(
                          directory: _directory,
                          select: (d) => d.favorites,
                          builder: (context) => ListenableBuilder(
                            listenable: recents,
                            builder: (context, _) => SliverToBoxAdapter(
                              child:
                                  recents.apps.isNotEmpty &&
                                      _search.text.isEmpty &&
                                      !_directory.favorites
                                  ? MiniAppRecentSection(
                                      apps: recents.apps,
                                      openingId: _openingAppId,
                                      onOpen: _open,
                                      onInfo: _info,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        _DirectorySelector(
                          directory: _directory,
                          select: (d) => (d.favorites, d.total, d.sort),
                          builder: (context) => SliverPadding(
                            // 最近使用区会随收藏筛选显隐，保留按钮组的选中反馈状态。
                            key: const ValueKey('mini-app-directory-filters'),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (loggedIn)
                                    SizedBox(
                                      width: 400,
                                      child: M3eButtonGroup<bool>(
                                        items: [
                                          M3eButtonGroupItem(
                                            value: false,
                                            label: Text(l.miniApp_discover),
                                            icon: const Icon(
                                              Symbols.explore_rounded,
                                            ),
                                          ),
                                          M3eButtonGroupItem(
                                            value: true,
                                            label: Text(l.miniApp_favorites),
                                            icon: const Icon(
                                              Symbols.bookmark_rounded,
                                            ),
                                          ),
                                        ],
                                        selected: _directory.favorites,
                                        onSelected: (value) =>
                                            _filter(favorites: value),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _search.text.isNotEmpty
                                              ? l.miniApp_searchResults
                                              : l.miniApp_count(
                                                  _directory.total,
                                                ),
                                          style: theme.textTheme.labelMedium
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                      SwipeDismissiblePopupMenuButton<String>(
                                        key: const ValueKey(
                                          'mini-app-sort-menu',
                                        ),
                                        tooltip: l.miniApp_sort,
                                        position: PopupMenuPosition.under,
                                        shape: RoundedSuperellipseBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        initialValue: _directory.sort,
                                        onSelected: (value) =>
                                            _filter(sort: value),
                                        itemBuilder: (_) => [
                                          for (final entry in sorts.entries)
                                            CheckedPopupMenuItem(
                                              value: entry.key,
                                              checked:
                                                  entry.key == _directory.sort,
                                              child: Text(entry.value),
                                            ),
                                        ],
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 12,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                sorts[_directory.sort]!,
                                                style:
                                                    theme.textTheme.labelLarge,
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(
                                                Symbols.sort_rounded,
                                                size: 18,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        _DirectorySelector(
                          directory: _directory,
                          select: (d) => (
                            d.apps,
                            d.favorites,
                            d.apps.isEmpty && d.loading,
                            d.apps.isEmpty ? d.error : null,
                          ),
                          builder: _buildDirectoryContent,
                        ),
                        _DirectorySelector(
                          directory: _directory,
                          select: (d) => (
                            d.apps.isEmpty,
                            d.loading || d.loadingMore,
                            d.error != null,
                            d.hasMore,
                          ),
                          builder: (context) => SliverToBoxAdapter(
                            child: _directory.apps.isEmpty
                                ? null
                                : Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Center(
                                      child:
                                          _directory.loadingMore ||
                                              _directory.loading
                                          ? const LoadingSpinner.standard()
                                          : _directory.error != null
                                          ? TextButton.icon(
                                              onPressed: () =>
                                                  _directory.hasMore
                                                  ? _directory.loadMore()
                                                  : _directory.refresh(),
                                              icon: const Icon(
                                                Symbols.refresh_rounded,
                                              ),
                                              label: Text(l.miniApp_retry),
                                            )
                                          : _directory.hasMore
                                          ? TextButton(
                                              onPressed: _directory.loadMore,
                                              child: Text(l.miniApp_loadMore),
                                            )
                                          : Text(
                                              l.miniApp_endOfList,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                    ),
                                  ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: MediaQuery.paddingOf(context).bottom + 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDirectoryContent(BuildContext context) {
    final apps = _directory.apps;
    if (_directory.loading && apps.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: LoadingSpinner()),
      );
    }
    if (apps.isEmpty && _directory.error != null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorView(
          error: _directory.error!,
          onRetry: () => _directory.refresh(),
        ),
      );
    }
    if (apps.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: MiniAppDirectoryEmpty(
          favorites: _directory.favorites && _search.text.isEmpty,
          onDiscover: () {
            _search.clear();
            _filter(favorites: false);
          },
        ),
      );
    }
    if (!identical(apps, _cardApps)) {
      _cardApps = apps;
      final ids = {for (final app in apps) app.id};
      _cards.removeWhere((id, _) => !ids.contains(id));
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context);
          // 给标题和完整统计留足宽度，窄屏及大字号使用单列。
          final minCardWidth = 264 * (scale.scale(14) / 14).clamp(1.0, 2.0);
          final columns =
              ((constraints.crossAxisExtent + 10) / (minCardWidth + 10))
                  .floor()
                  .clamp(1, 3);
          if (columns == 1) {
            return SliverList.builder(
              itemCount: apps.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: SegmentedCardItem(
                  index: index,
                  count: apps.length,
                  child: _card(apps[index], row: true),
                ),
              ),
            );
          }
          return SliverList.builder(
            itemCount: (apps.length + columns - 1) ~/ columns,
            itemBuilder: (context, row) {
              final start = row * columns;
              final end = (start + columns).clamp(0, apps.length);
              final rowApps = apps.sublist(start, end);
              // 每次只布局可见行的两到三张卡片，行高由实际内容决定。
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, app) in rowApps.indexed) ...[
                        if (index > 0) const SizedBox(width: 10),
                        Expanded(child: _card(app, row: false)),
                      ],
                      for (
                        var index = rowApps.length;
                        index < columns;
                        index++
                      ) ...[
                        const SizedBox(width: 10),
                        const Expanded(child: SizedBox.shrink()),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 追加分页后已有卡片返回同一实例，框架跳过它们的重建，只构建新增卡片。
  Widget _card(MiniApp app, {required bool row}) {
    final opening = _openingAppId == app.id;
    final cached = _cards[app.id];
    if (cached != null &&
        identical(cached.app, app) &&
        cached.opening == opening &&
        cached.row == row) {
      return cached.widget;
    }
    final Widget card = row
        ? MiniAppDiscoveryRow(
            app: app,
            opening: opening,
            onOpen: () => _open(app),
            onInfo: () => _info(app),
          )
        : RepaintBoundary(
            child: MiniAppDiscoveryCard(
              key: ValueKey(app.id),
              app: app,
              opening: opening,
              onOpen: () => _open(app),
              onInfo: () => _info(app),
            ),
          );
    _cards[app.id] = (app: app, opening: opening, row: row, widget: card);
    return card;
  }

  Future<void> _info(MiniApp app) async {
    if (_showingInfo || _openingAppId != null || !_active) return;
    _showingInfo = true;
    FocusScope.of(context).unfocus();
    if (!PlatformUtils.isDesktop) unawaited(HapticFeedback.selectionClick());
    final generation = AuthSession().generation;
    try {
      final launched = await MiniAppDetailPage.show(context, app.id);
      if (launched && mounted && AuthSession().isValid(generation)) {
        _directory.refresh();
      }
    } finally {
      _showingInfo = false;
    }
  }

  Future<void> _open(MiniApp app) async {
    if (_openingAppId != null || _showingInfo) return;
    FocusScope.of(context).unfocus();
    final generation = AuthSession().generation;
    setState(() => _openingAppId = app.id);
    try {
      final details = await ref.read(miniAppServiceProvider).details(app.id);
      if (!mounted || !_active || !AuthSession().isValid(generation)) {
        return;
      }
      await MiniAppRunnerPage.open(context, details);
      if (mounted && AuthSession().isValid(generation)) _directory.refresh();
    } catch (_) {
      if (mounted) {
        ToastService.showError(context.l10n.miniApp_unavailable);
      }
    } finally {
      if (mounted) setState(() => _openingAppId = null);
    }
  }
}

/// 只在选取的目录状态变化时重建；页面自身 setState 时随父级正常重建。
class _DirectorySelector extends StatefulWidget {
  const _DirectorySelector({
    required this.directory,
    required this.select,
    required this.builder,
  });
  final MiniAppDirectoryController directory;
  final Object? Function(MiniAppDirectoryController directory) select;
  final WidgetBuilder builder;

  @override
  State<_DirectorySelector> createState() => _DirectorySelectorState();
}

class _DirectorySelectorState extends State<_DirectorySelector> {
  late Object? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.select(widget.directory);
    widget.directory.addListener(_changed);
  }

  @override
  void didUpdateWidget(_DirectorySelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.directory != widget.directory) {
      oldWidget.directory.removeListener(_changed);
      widget.directory.addListener(_changed);
    }
    _selected = widget.select(widget.directory);
  }

  void _changed() {
    final selected = widget.select(widget.directory);
    if (selected == _selected) return;
    setState(() => _selected = selected);
  }

  @override
  void dispose() {
    widget.directory.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
