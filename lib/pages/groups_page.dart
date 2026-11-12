import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/user_group.dart';
import '../providers/core_providers.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/content/collapsed_html_content.dart';
import 'group_page.dart';
import 'groups/group_identity.dart';

class GroupsPage extends ConsumerStatefulWidget {
  const GroupsPage({
    super.key,
    this.initialFilter = '',
    this.initialType,
    this.initialOrder,
    this.initialAscending = true,
    this.username,
  });

  final String initialFilter;
  final String? initialType;
  final GroupDirectoryOrder? initialOrder;
  final bool initialAscending;
  final String? username;

  @override
  ConsumerState<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends ConsumerState<GroupsPage> {
  final _scrollController = ScrollController();
  late final _searchController = TextEditingController(
    text: widget.initialFilter,
  );
  late String _filter = widget.initialFilter.trim();
  late String? _type = widget.initialType;
  late GroupDirectoryOrder? _order = widget.initialOrder;
  late bool _ascending = widget.initialAscending;
  List<UserGroupDetail> _groups = [];
  List<String> _typeFilters = [];
  Timer? _debounce;
  int _request = 0;
  int _nextPage = 0;
  int _received = 0;
  int? _total;
  bool _loading = false;
  bool _hasMore = false;
  bool _failedLoadMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool loadMore = false}) async {
    if (loadMore && (_loading || !_hasMore)) return;
    _debounce?.cancel();
    final request = ++_request;
    final page = loadMore ? _nextPage : 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(discourseServiceProvider)
          .getGroups(
            filter: _filter,
            type: _type,
            order: _order,
            ascending: _ascending,
            page: page,
            username: widget.username,
          );
      if (!mounted || request != _request) return;
      setState(() {
        _groups = {
          if (loadMore)
            for (final group in _groups) group.group.name: group,
          for (final group in result.groups) group.group.name: group,
        }.values.toList();
        _typeFilters = result.typeFilters;
        _total = result.total;
        _received = (loadMore ? _received : 0) + result.groups.length;
        _nextPage =
            int.tryParse(
              Uri.tryParse(result.moreUrl ?? '')?.queryParameters['page'] ?? '',
            ) ??
            page + 1;
        _hasMore =
            result.moreUrl != null &&
            result.groups.isNotEmpty &&
            _received < result.total &&
            _nextPage > page;
      });
    } catch (error) {
      if (mounted && request == _request) {
        setState(() {
          _error = error;
          _failedLoadMore = loadMore;
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 240 && _error == null) {
      _load(loadMore: true);
    }
  }

  void _resetResults() {
    _request++;
    _debounce?.cancel();
    setState(() {
      _groups = [];
      _total = null;
      _error = null;
      _loading = true;
      _hasMore = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _search(String value) {
    _filter = value.trim();
    _resetResults();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _openGroup(UserGroupDetail group) async {
    await Navigator.of(context).push(
      InteractionPageRoute(builder: (_) => GroupPage(name: group.group.name)),
    );
    if (!mounted) return;
    // 返回目录时重读服务端筛选结果，加入或退出后“我的用户组”也同步更新。
    await _load();
  }

  String _typeLabel(String? type) => switch (type) {
    null => context.l10n.group_allGroups,
    'my' => context.l10n.group_myGroups,
    'owner' => context.l10n.group_ownedGroups,
    'public' => context.l10n.group_publicGroups,
    'close' => context.l10n.group_closedGroups,
    'automatic' => context.l10n.group_automaticGroups,
    'non_automatic' => context.l10n.group_customGroups,
    _ => type,
  };

  String _orderLabel(GroupDirectoryOrder? order) => switch (order) {
    null => context.l10n.group_sortDefault,
    GroupDirectoryOrder.name => context.l10n.group_sortName,
    GroupDirectoryOrder.members => context.l10n.group_sortCount,
  };

  Widget _buildSearch() => InputFieldShell(
    child: TextField(
      controller: _searchController,
      onChanged: _search,
      textInputAction: TextInputAction.search,
      textAlignVertical: TextAlignVertical.center,
      onSubmitted: (_) => _load(),
      decoration: InputDecoration(
        visualDensity: VisualDensity.standard,
        hintText: context.l10n.group_searchGroups,
        prefixIcon: const Icon(Symbols.search_rounded),
        suffixIcon: _filter.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.common_clear,
                onPressed: () {
                  _searchController.clear();
                  _search('');
                },
                icon: const Icon(Symbols.close_rounded),
              ),
      ),
    ),
  );

  Widget _buildTypeFilter() => SwipeDismissiblePopupMenuButton<String>(
    tooltip: context.l10n.group_filterType,
    onSelected: (value) {
      final type = value.isEmpty ? null : value;
      if (type == _type) return;
      _type = type;
      _resetResults();
      _load();
    },
    itemBuilder: (_) => [
      for (final type in <String?>{null, ..._typeFilters, ?_type})
        CheckedPopupMenuItem(
          value: type ?? '',
          checked: _type == type,
          child: Text(_typeLabel(type)),
        ),
    ],
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              _typeLabel(_type),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Symbols.expand_more_rounded, size: 18),
        ],
      ),
    ),
  );

  Widget _buildSort() =>
      SwipeDismissiblePopupMenuButton<({GroupDirectoryOrder? order})>(
        tooltip: context.l10n.group_sortGroups,
        icon: const Icon(Symbols.sort_rounded),
        onSelected: (selection) {
          _order = selection.order;
          _ascending = _order != GroupDirectoryOrder.members;
          _resetResults();
          _load();
        },
        itemBuilder: (_) => [
          for (final order in <GroupDirectoryOrder?>[
            null,
            ...GroupDirectoryOrder.values,
          ])
            CheckedPopupMenuItem(
              value: (order: order),
              checked: order == _order,
              child: Text(_orderLabel(order)),
            ),
        ],
      );

  Widget _buildToolbar() {
    final theme = Theme.of(context);
    final sorting = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildSort(),
        if (_order != null)
          IconButton(
            tooltip: _ascending
                ? context.l10n.group_ascending
                : context.l10n.group_descending,
            icon: Icon(
              _ascending
                  ? Symbols.arrow_upward_rounded
                  : Symbols.arrow_downward_rounded,
            ),
            onPressed: () {
              _ascending = !_ascending;
              _resetResults();
              _load();
            },
          ),
      ],
    );
    final count = _total == null
        ? const SizedBox.shrink()
        : Text(
            context.l10n.group_totalGroups(_total!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (largeText)
          _buildSearch()
        else
          Row(
            children: [
              Expanded(child: _buildSearch()),
              const SizedBox(width: 8),
              sorting,
            ],
          ),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildTypeFilter(),
              ),
            ),
            const SizedBox(width: 12),
            if (largeText)
              sorting
            else
              Flexible(
                child: Align(alignment: Alignment.centerRight, child: count),
              ),
          ],
        ),
        if (largeText && _total != null)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: count),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.username == null
              ? context.l10n.userProfile_groups
              : '@${widget.username} · ${context.l10n.userProfile_groups}',
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _buildToolbar(),
                ),
                Expanded(
                  child: M3eRefreshIndicator(
                    onRefresh: _load,
                    child: CustomScrollView(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (_groups.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _loading
                                ? const Center(child: LoadingSpinner())
                                : _error != null
                                ? ErrorView(error: _error!, onRetry: _load)
                                : AppEmptyState(
                                    icon: const Icon(Symbols.groups_rounded),
                                    title: context.l10n.group_noGroups,
                                  ),
                          ),
                        if (_groups.isNotEmpty) ...[
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            sliver: SliverLayoutBuilder(
                              builder: (context, constraints) {
                                final columns =
                                    constraints.crossAxisExtent >= 720 &&
                                        MediaQuery.textScalerOf(context)
                                                .scale(14) <
                                            21
                                    ? 2
                                    : 1;
                                return SliverList.builder(
                                  itemCount: (_groups.length / columns).ceil(),
                                  itemBuilder: (context, row) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: IntrinsicHeight(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          for (
                                            var column = 0;
                                            column < columns;
                                            column++
                                          ) ...[
                                            if (column > 0)
                                              const SizedBox(width: 12),
                                            Expanded(
                                              child:
                                                  row * columns + column >=
                                                      _groups.length
                                                  ? const SizedBox.shrink()
                                                  : SegmentedCardItem(
                                                      key: ValueKey(
                                                        _groups[row * columns +
                                                                column]
                                                            .group
                                                            .name,
                                                      ),
                                                      index: 0,
                                                      count: 1,
                                                      child: _GroupDirectoryTile(
                                                        group:
                                                            _groups[row *
                                                                    columns +
                                                                column],
                                                        onTap: () => _openGroup(
                                                          _groups[row *
                                                                  columns +
                                                              column],
                                                        ),
                                                      ),
                                                    ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: PagedListFooter(
                              hasMore: _hasMore,
                              isLoadingMore: _loading,
                              isLoadMoreFailed: _error != null,
                              onRetry: () => _load(loadMore: _failedLoadMore),
                            ),
                          ),
                        ],
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
}

class _GroupDirectoryTile extends StatelessWidget {
  const _GroupDirectoryTile({required this.group, required this.onTap});
  final UserGroupDetail group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = group.bioExcerpt ?? group.bio;
    return InkWell(
      onTap: onTap,
      borderRadius: SegmentedCardItem.borderRadiusOf(
        context,
        index: 0,
        count: 1,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GroupAvatar(group: group),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@${group.group.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Symbols.chevron_right_rounded, size: 18),
              ],
            ),
            if (description?.isNotEmpty == true) ...[
              const SizedBox(height: 14),
              CollapsedHtmlContent(
                html: description!,
                maxLines: 2,
                textStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const Spacer(),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (group.group.userCount != null)
                  Text(
                    context.l10n.group_memberCount(group.group.userCount!),
                    style: theme.textTheme.labelMedium,
                  ),
                GroupMembershipLabel(group: group),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
