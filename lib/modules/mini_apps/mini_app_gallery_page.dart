import 'dart:async';

import '../../services/toast_service.dart';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
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
    this.workspace = false,
  });
  final VoidCallback? onClose;
  final bool active;
  final bool workspace;
  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push<void>(InteractionPageRoute(builder: (_) => const MiniAppGalleryPage()));
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

  @override
  void initState() {
    super.initState();
    _directory = MiniAppDirectoryController(
      ref.read(miniAppServiceProvider).directory,
    );
    if (widget.active) _directory.refresh();
    AuthSession().generationChanges.addListener(_accountChanged);
    _windowUpdates = MiniAppWindowBridge.updates.stream.listen((_) {
      _windowUpdatesPending = true;
      _windowRefresh?.cancel();
      _windowRefresh = Timer(const Duration(milliseconds: 250), () {
        if (mounted && widget.active) {
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
        enabled: () => mounted && widget.active,
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
      shouldRefresh: () => widget.active,
      onRefresh: _refresh,
      child: child,
    );
  }

  @override
  void didUpdateWidget(MiniAppGalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        !oldWidget.active &&
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
    if (!widget.active) {
      _directory.invalidate();
      _reloadOnActivate = true;
      return;
    }
    _directory.update(favorites: false, query: _search.text.trim());
  }

  void _nearEnd() {
    if (widget.active &&
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
  }

  @override
  void dispose() {
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
          !widget.active ||
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
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListenableBuilder(
              listenable: Listenable.merge([_directory, recents]),
              builder: (context, _) => Column(
                children: [
                  MiniAppGalleryHeader(
                    onClose: widget.workspace
                        ? null
                        : widget.onClose ?? () => Navigator.maybePop(context),
                    isLayer: !PlatformUtils.isDesktop && widget.onClose != null,
                    onRefresh: PlatformUtils.isDesktop ? _refresh : null,
                    refreshing: _directory.loading,
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
                          if (recents.apps.isNotEmpty &&
                              _search.text.isEmpty &&
                              !_directory.favorites)
                            SliverToBoxAdapter(
                              child: MiniAppRecentSection(
                                apps: recents.apps,
                                openingId: _openingAppId,
                                onOpen: _open,
                                onInfo: _info,
                              ),
                            ),
                          SliverPadding(
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
                          if (_directory.loading && _directory.apps.isEmpty)
                            const SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(child: LoadingSpinner()),
                            )
                          else if (_directory.apps.isEmpty &&
                              _directory.error != null)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: ErrorView(
                                error: _directory.error!,
                                onRetry: () => _directory.refresh(),
                              ),
                            )
                          else if (_directory.apps.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: MiniAppDirectoryEmpty(
                                favorites:
                                    _directory.favorites &&
                                    _search.text.isEmpty,
                                onDiscover: () {
                                  _search.clear();
                                  _filter(favorites: false);
                                },
                              ),
                            )
                          else ...[
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              sliver: SliverLayoutBuilder(
                                builder: (context, constraints) {
                                  final scale = MediaQuery.textScalerOf(
                                    context,
                                  );
                                  final columns =
                                      (constraints.crossAxisExtent /
                                              (164 *
                                                  scale
                                                      .scale(1)
                                                      .clamp(1.0, 1.6)))
                                          .floor()
                                          .clamp(1, 3);
                                  if (columns == 1) {
                                    return SliverList.builder(
                                      itemCount: _directory.apps.length,
                                      itemBuilder: (context, index) {
                                        final app = _directory.apps[index];
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 3,
                                          ),
                                          child: SegmentedCardItem(
                                            index: index,
                                            count: _directory.apps.length,
                                            child: MiniAppDiscoveryRow(
                                              app: app,
                                              opening: _openingAppId == app.id,
                                              onOpen: () => _open(app),
                                              onInfo: () => _info(app),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  }
                                  return SliverGrid.builder(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          crossAxisSpacing: 10,
                                          mainAxisSpacing: 10,
                                          mainAxisExtent:
                                              110 + scale.scale(104),
                                        ),
                                    itemCount: _directory.apps.length,
                                    itemBuilder: (context, index) {
                                      final app = _directory.apps[index];
                                      return MiniAppDiscoveryCard(
                                        app: app,
                                        opening: _openingAppId == app.id,
                                        onOpen: () => _open(app),
                                        onInfo: () => _info(app),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child:
                                      _directory.loadingMore ||
                                          _directory.loading
                                      ? const LoadingSpinner(size: 28)
                                      : _directory.error != null
                                      ? TextButton.icon(
                                          onPressed: () => _directory.hasMore
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
                          ],
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
      ),
    );
  }

  Future<void> _info(MiniApp app) async {
    if (_showingInfo || _openingAppId != null || !widget.active) return;
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
      if (!mounted || !widget.active || !AuthSession().isValid(generation)) {
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
