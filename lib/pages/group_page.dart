import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/category.dart';
import '../models/topic.dart';
import '../models/user.dart';
import '../models/user_group.dart';
import '../providers/category_provider.dart';
import '../providers/core_providers.dart';
import '../services/preloaded_data_service.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/error_utils.dart';
import '../utils/fluxdo_render_callbacks.dart';
import '../utils/link_launcher.dart';
import '../widgets/common/category_selection_sheet.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/topic/topic_item_builder.dart';
import 'groups/group_content.dart';
import 'groups/group_identity.dart';
import 'groups/group_controls.dart';
import 'login_page.dart';
import 'groups_page.dart';

/// 用户组成员、活动与分类权限，操作能力由服务端返回的权限决定。
class GroupPage extends ConsumerStatefulWidget {
  const GroupPage({
    super.key,
    required this.name,
    this.initialSection = GroupSection.members,
    this.initialActivityFilter = GroupActivityFilter.posts,
    this.initialCategoryId,
  });

  final String name;
  final GroupSection initialSection;
  final GroupActivityFilter initialActivityFilter;
  final int? initialCategoryId;

  @override
  ConsumerState<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends ConsumerState<GroupPage>
    with TickerProviderStateMixin {
  static const _pageConstraints = BoxConstraints(maxWidth: 1080);

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _headerKey = GlobalKey();
  late final TabController _tabs;
  late final AnimationController _contentFade;
  late GroupSection _section;
  late GroupActivityFilter _activityFilter;
  late int? _categoryId;
  Timer? _searchDebounce;
  UserGroupDetail? _group;
  bool _loading = false;
  bool _mutating = false;
  bool _requestSent = false;
  bool _permissionsCurrent = false;
  Object? _error;
  final _loaded = <GroupSection>{};

  List<User> _members = [];
  Set<int> _ownerIds = {};
  Map<int, DateTime?> _joinedAt = {};
  bool _membersLoading = false;
  bool _membersHaveMore = false;
  int _nextOffset = 0;
  int _membersRequest = 0;
  String _query = '';
  GroupMemberOrder? _memberOrder;
  bool _ascending = true;
  Object? _membersError;
  bool _membersFailedLoadMore = false;

  List<GroupActivityPost> _posts = [];
  List<Topic> _topics = [];
  final _activityCategories = <int, Category>{};
  bool _activityLoading = false;
  bool _activityHasMore = false;
  int _activityRequest = 0;
  int _nextTopicPage = 0;
  DateTime? _before;
  Object? _activityError;
  bool _activityFailedLoadMore = false;

  List<GroupCategoryPermission> _permissions = [];
  bool _permissionsLoading = false;
  int _permissionRequest = 0;
  Object? _permissionsError;

  bool get _canReadMembers =>
      _permissionsCurrent && _group?.canSeeMembers == true;
  bool get _mentionsEnabled =>
      PreloadedDataService().siteSettingsSync?['enable_mentions'] != false;

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    _activityFilter = widget.initialActivityFilter;
    if (!_mentionsEnabled && _activityFilter == GroupActivityFilter.mentions) {
      _activityFilter = GroupActivityFilter.posts;
    }
    _categoryId = widget.initialCategoryId;
    _tabs = TabController(
      length: GroupSection.values.length,
      vsync: this,
      initialIndex: _section.index,
    );
    _tabs.addListener(_onTabChanged);
    _contentFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 1,
    );
    _scrollController.addListener(_onScroll);
    _loadGroup();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _tabs.dispose();
    _contentFade.dispose();
    super.dispose();
  }

  void _invalidateSections({bool clear = false}) {
    _searchDebounce?.cancel();
    _membersRequest++;
    _activityRequest++;
    _permissionRequest++;
    _loaded.clear();
    _membersLoading = false;
    _activityLoading = false;
    _permissionsLoading = false;
    if (clear) {
      _members = [];
      _ownerIds = {};
      _joinedAt = {};
      _posts = [];
      _topics = [];
      _permissions = [];
      _membersHaveMore = false;
      _activityHasMore = false;
    }
  }

  Future<void> _loadGroup() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _invalidateSections();
    });
    GroupSection? refreshedSection;
    try {
      final group = await ref
          .read(discourseServiceProvider)
          .getGroup(widget.name);
      if (!mounted) return;
      setState(() {
        _group = group;
        _permissionsCurrent = true;
        if (!group.canSeeMembers) _invalidateSections(clear: true);
      });
      refreshedSection = _section;
      await _loadSection();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (refreshedSection != null &&
            refreshedSection != _section &&
            !_loaded.contains(_section)) {
          _loadSection();
        }
      }
    }
  }

  Future<void> _loadSection() => switch (_section) {
    GroupSection.members => _loadMembers(),
    GroupSection.activity => _loadActivity(),
    GroupSection.permissions => _loadPermissions(),
  };

  void _onTabChanged() {
    final section = GroupSection.values[_tabs.index];
    if (section == _section) return;
    _resetContentScroll();
    setState(() => _section = section);
    _contentFade.forward(from: MediaQuery.disableAnimationsOf(context) ? 1 : 0);
    if (!_loading && !_loaded.contains(section)) _loadSection();
  }

  void _resetContentScroll() {
    final header = _headerKey.currentContext?.findRenderObject();
    if (header is RenderBox &&
        _scrollController.hasClients &&
        _scrollController.offset > header.size.height) {
      _scrollController.jumpTo(header.size.height);
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _membersRequest++;
    setState(() {
      _query = value.trim();
      _members = [];
      _membersError = null;
      _membersLoading = true;
      _membersHaveMore = false;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 300), _loadMembers);
  }

  Future<void> _loadMembers({bool loadMore = false}) async {
    if (!_canReadMembers) return;
    if (loadMore && (_loading || _membersLoading || !_membersHaveMore)) return;
    final request = ++_membersRequest;
    setState(() {
      _membersLoading = true;
      _membersError = null;
    });
    try {
      final page = await ref
          .read(discourseServiceProvider)
          .getGroupMembers(
            _group!.group.name,
            filter: _query,
            offset: loadMore ? _nextOffset : 0,
            order: _memberOrder,
            ascending: _ascending,
          );
      if (!mounted || request != _membersRequest) return;
      setState(() {
        final members = {
          if (loadMore)
            for (final user in _members) user.id: user,
        };
        for (final user in page.members) {
          members[user.id] = user;
        }
        _members = members.values.toList();
        _ownerIds = {if (loadMore) ..._ownerIds, ...page.ownerIds};
        _joinedAt = {if (loadMore) ..._joinedAt, ...page.joinedAt};
        _nextOffset = page.offset + page.members.length;
        _membersHaveMore = page.hasMore;
        _loaded.add(GroupSection.members);
      });
    } catch (error) {
      if (mounted && request == _membersRequest) {
        setState(() {
          _membersError = error;
          _membersFailedLoadMore = loadMore;
        });
      }
    } finally {
      if (mounted && request == _membersRequest) {
        setState(() => _membersLoading = false);
      }
    }
  }

  Future<void> _loadActivity({bool loadMore = false}) async {
    if (!_canReadMembers) return;
    if (loadMore && (_loading || _activityLoading || !_activityHasMore)) return;
    final request = ++_activityRequest;
    final filter = _activityFilter;
    setState(() {
      _activityLoading = true;
      _activityError = null;
    });
    try {
      final service = ref.read(discourseServiceProvider);
      if (filter == GroupActivityFilter.topics) {
        final page = loadMore ? _nextTopicPage : 0;
        final result = await service.getGroupTopics(
          _group!.group.name,
          page: page,
          categoryId: _categoryId,
        );
        if (!mounted || request != _activityRequest) return;
        setState(() {
          _topics = {
            if (loadMore)
              for (final topic in _topics) topic.id: topic,
            for (final topic in result.topics) topic.id: topic,
          }.values.toList();
          _nextTopicPage = page + 1;
          _activityHasMore =
              result.moreTopicsUrl != null && result.topics.isNotEmpty;
        });
      } else {
        final result = await service.getGroupPosts(
          _group!.group.name,
          mentions: filter == GroupActivityFilter.mentions,
          before: loadMore ? _before : null,
          categoryId: _categoryId,
        );
        if (!mounted || request != _activityRequest) return;
        setState(() {
          _posts = {
            if (loadMore)
              for (final post in _posts) post.id: post,
            for (final post in result.posts) post.id: post,
          }.values.toList();
          _activityCategories.addEntries(
            result.categories.map((c) => MapEntry(c.id, c)),
          );
          final before = result.posts.lastOrNull?.createdAt;
          _activityHasMore =
              result.hasMore &&
              before != null &&
              (!loadMore || before != _before);
          _before = before;
        });
      }
      _loaded.add(GroupSection.activity);
    } catch (error) {
      if (mounted && request == _activityRequest) {
        setState(() {
          _activityError = error;
          _activityFailedLoadMore = loadMore;
        });
      }
    } finally {
      if (mounted && request == _activityRequest) {
        setState(() => _activityLoading = false);
      }
    }
  }

  Future<void> _loadPermissions() async {
    if (!_permissionsCurrent || _group == null) return;
    final request = ++_permissionRequest;
    setState(() {
      _permissionsLoading = true;
      _permissionsError = null;
    });
    try {
      final permissions = await ref
          .read(discourseServiceProvider)
          .getGroupPermissions(_group!.group.name);
      if (!mounted || request != _permissionRequest) return;
      setState(() {
        _permissions = permissions;
        _loaded.add(GroupSection.permissions);
      });
    } catch (error) {
      if (mounted && request == _permissionRequest) {
        setState(() => _permissionsError = error);
      }
    } finally {
      if (mounted && request == _permissionRequest) {
        setState(() => _permissionsLoading = false);
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter >= 240) return;
    if (_section == GroupSection.members && _membersError == null) {
      _loadMembers(loadMore: true);
    }
    if (_section == GroupSection.activity && _activityError == null) {
      _loadActivity(loadMore: true);
    }
  }

  Future<bool> _ensureLogin() async {
    if (ref.read(currentUserProvider).value != null) return true;
    final container = ProviderScope.containerOf(context, listen: false);
    final result = await Navigator.of(context)
        .push<bool>(InteractionPageRoute(builder: (_) => const LoginPage()));
    if (result != true) return false;
    // 登录会刷新全局状态，等待路由与账号数据稳定后再读取用户组权限。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return false;
    final user =
        await container.read(currentUserProvider.future) ??
        await container.refresh(currentUserProvider.future);
    if (!mounted || user == null) return false;
    await _loadGroup();
    return mounted && _error == null && _permissionsCurrent;
  }

  Future<void> _changeMembership() async {
    if (_mutating || _loading) return;
    final joining = !_group!.isMember;
    // 先锁定操作，避免登录、确认框和网络请求重复提交。
    setState(() => _mutating = true);
    try {
      if (!await _ensureLogin() || !mounted) return;
      final group = _group!;
      final id = group.group.id;
      // 登录后的成员身份可能变化，保留点击时的加入或离开意图。
      if (group.isMember == joining ||
          id == null ||
          (joining ? !group.publicAdmission : !group.publicExit)) {
        return;
      }
      if (!joining && !group.publicAdmission) {
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.group_leave),
            content: Text(context.l10n.group_leaveConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(context.l10n.group_leave),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      final service = ref.read(discourseServiceProvider);
      if (joining) {
        await service.joinGroup(id);
      } else {
        await service.leaveGroup(id);
      }
      if (!mounted) return;
      setState(() {
        _group = group.withMembership(joining);
        _permissionsCurrent = false;
        _invalidateSections(clear: true);
      });
      await _loadGroup();
    } catch (error) {
      if (mounted) {
        ToastService.showError(ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _requestMembership() async {
    if (_mutating || _loading || _requestSent) return;
    setState(() => _mutating = true);
    try {
      if (!await _ensureLogin() ||
          !mounted ||
          _group!.isMember ||
          !_group!.allowMembershipRequests) {
        return;
      }
      final result = await showAppDialog<({String? url})>(
        context: context,
        barrierDismissible: false,
        builder: (_) => GroupMembershipRequestDialog(group: _group!),
      );
      if (!mounted || result == null) return;
      setState(() => _requestSent = true);
      ToastService.showSuccess(context.l10n.group_requestSent);
      if (result.url != null) launchContentLink(context, result.url!);
    } catch (error) {
      if (mounted) {
        ToastService.showError(ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _selectCategory() async {
    try {
      final categories = await ref.read(categoriesProvider.future);
      if (!mounted) return;
      final choices = {
        for (final category in categories) category.id: category,
        ..._activityCategories,
      };
      final result = await showAppBottomSheet<({Category? category})>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => CategorySelectionSheet.filter(
          categories: choices.values.toList(),
          selectedCategory: choices[_categoryId],
          onSelected: (category) =>
              Navigator.of(sheetContext).pop((category: category)),
        ),
      );
      if (!mounted || result == null || result.category?.id == _categoryId) {
        return;
      }
      setState(() => _categoryId = result.category?.id);
      await _reloadActivityFilter();
    } catch (error) {
      if (mounted) {
        ToastService.showError(ErrorUtils.getErrorInfo(error).message);
      }
    }
  }

  Future<void> _reloadActivityFilter() async {
    _resetContentScroll();
    setState(() {
      _posts = [];
      _topics = [];
      _activityHasMore = false;
      _loaded.remove(GroupSection.activity);
    });
    await _loadActivity();
  }

  String _memberOrderLabel(GroupMemberOrder? order) => switch (order) {
    null => context.l10n.group_sortDefault,
    GroupMemberOrder.username => context.l10n.forumPrefs_username,
    GroupMemberOrder.joined => context.l10n.group_joinedAt,
    GroupMemberOrder.lastPosted => context.l10n.userProfile_lastPosted,
    GroupMemberOrder.lastSeen => context.l10n.userProfile_lastSeen,
  };

  void _sortMembers(GroupMemberOrder? order, bool ascending) {
    _searchDebounce?.cancel();
    _resetContentScroll();
    setState(() {
      _memberOrder = order;
      _ascending = ascending;
      _members = [];
      _membersHaveMore = false;
    });
    _loadMembers();
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final currentUser = ref.watch(currentUserProvider).value;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: PageBackdrop(
          child: Center(
            child: ConstrainedBox(
              constraints: _pageConstraints,
              child: AppBar(
                titleSpacing: 24,
                title: Text(context.l10n.userProfile_groups),
                actionsPadding: const EdgeInsets.only(right: 16),
                actions: [
                  IconButton(
                    tooltip: context.l10n.group_allGroups,
                    icon: const Icon(Symbols.groups_rounded),
                    onPressed: () => Navigator.of(context).push(
                      InteractionPageRoute(builder: (_) => const GroupsPage()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: _pageConstraints,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: group == null
                  ? _error != null
                        ? ErrorView(error: _error!, onRetry: _loadGroup)
                        : const Center(child: LoadingSpinner())
                  : M3eRefreshIndicator(
                      onRefresh: _mutating ? () async {} : _loadGroup,
                      child: CustomScrollView(
                        controller: _scrollController,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: _buildHeader(group, currentUser),
                          ),
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _GroupTabsHeader(
                              height:
                                  32 +
                                  MediaQuery.textScalerOf(context).scale(16),
                              child: PageBackdrop(
                                child: TabBar(
                                  controller: _tabs,
                                  isScrollable:
                                      MediaQuery.textScalerOf(context)
                                          .scale(14) >
                                      20,
                                  tabAlignment:
                                      MediaQuery.textScalerOf(context)
                                              .scale(14) >
                                          20
                                      ? TabAlignment.start
                                      : TabAlignment.fill,
                                  tabs: [
                                    for (final (icon, label) in [
                                      (
                                        Symbols.group_rounded,
                                        context.l10n.group_members,
                                      ),
                                      (
                                        Symbols.article_rounded,
                                        context.l10n.group_activity,
                                      ),
                                      (
                                        Symbols.shield_rounded,
                                        context.l10n.group_permissions,
                                      ),
                                    ])
                                      Tab(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ExcludeSemantics(
                                              child: Icon(icon, size: 18),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(label),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_error != null)
                            SliverToBoxAdapter(
                              child: ErrorView(
                                error: _error!,
                                onRetry: _loadGroup,
                              ),
                            ),
                          if (_permissionsCurrent)
                            SliverFadeTransition(
                              opacity: _contentFade,
                              sliver: SliverMainAxisGroup(
                                slivers: switch (_section) {
                                  GroupSection.members => _buildMembers(),
                                  GroupSection.activity => _buildActivity(),
                                  GroupSection.permissions =>
                                    _buildPermissions(),
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(UserGroupDetail group, User? currentUser) {
    final theme = Theme.of(context);
    final disabled = _loading || _mutating;
    final actions = <Widget>[
      if (currentUser != null && group.messageable)
        OutlinedButton.icon(
          onPressed: disabled
              ? null
              : () => showReplySheet(
                  context: context,
                  targetUsername: group.group.name,
                ),
          icon: const Icon(Symbols.mail_rounded, size: 18),
          label: Text(context.l10n.group_message),
        ),
      if (group.isMember && group.publicExit)
        OutlinedButton.icon(
          onPressed: disabled ? null : _changeMembership,
          icon: const Icon(Symbols.logout_rounded, size: 18),
          label: Text(context.l10n.group_leave),
        )
      else if (!group.isMember && group.publicAdmission)
        FilledButton.icon(
          onPressed: disabled ? null : _changeMembership,
          icon: const Icon(Symbols.group_add_rounded, size: 18),
          label: Text(context.l10n.group_join),
        )
      else if (!group.isMember && group.allowMembershipRequests)
        FilledButton.icon(
          onPressed: disabled || _requestSent ? null : _requestMembership,
          icon: Icon(
            _requestSent ? Symbols.check_rounded : Symbols.person_add_rounded,
            size: 18,
          ),
          label: Text(
            _requestSent
                ? context.l10n.group_requestSent
                : context.l10n.group_request,
          ),
        ),
    ];
    final identity = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GroupAvatar(group: group, size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group.displayName, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '@${group.group.name}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (group.group.userCount != null)
                    Text(
                      context.l10n.group_memberCount(group.group.userCount!),
                      style: theme.textTheme.labelMedium,
                    ),
                  if (group.isMember || group.isOwner || group.automatic)
                    GroupMembershipLabel(group: group),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    final biography = group.bio?.isNotEmpty == true
        ? Padding(
            padding: const EdgeInsets.only(top: 12),
            child:
                FluxdoRenderCallbacks.generic(
                  heroTagNamespace: 'group_${group.group.name}',
                ).render(
                  cookedHtml: group.bio!,
                  baseTextStyle: theme.textTheme.bodyMedium,
                  selectionEnabled: false,
                ),
          )
        : const SizedBox.shrink();
    return Padding(
      key: _headerKey,
      padding: const EdgeInsets.only(top: 12, bottom: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth > 720 &&
              MediaQuery.textScalerOf(context).scale(14) < 20;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: identity),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(width: 24),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: actions,
                        ),
                      ),
                    ],
                  ],
                )
              else
                identity,
              biography,
              if (!wide && actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _emptySliver({required String title, IconData? icon}) =>
      SliverFillRemaining(
        hasScrollBody: false,
        child: AppEmptyState(
          title: title,
          icon: Icon(icon ?? Symbols.group_rounded),
        ),
      );

  Widget _statusSliver({
    required bool loading,
    Object? error,
    required VoidCallback retry,
    required String empty,
  }) => SliverFillRemaining(
    hasScrollBody: false,
    child: loading
        ? const Center(child: LoadingSpinner())
        : error != null
        ? ErrorView(error: error, onRetry: retry)
        : AppEmptyState(title: empty, icon: const Icon(Symbols.inbox_rounded)),
  );

  Widget _buildMemberColumns() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        if (!GroupMemberColumns.isWide(context, constraints.maxWidth)) {
          return const SizedBox.shrink();
        }
        return GroupMemberColumns(
          cellPadding: EdgeInsets.zero,
          children: [
            for (final order in GroupMemberOrder.values)
              TextButton(
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant,
                ),
                onPressed: _loading
                    ? null
                    : () => _sortMembers(
                        order,
                        order == _memberOrder
                            ? !_ascending
                            : order == GroupMemberOrder.username,
                      ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _memberOrderLabel(order),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (order == _memberOrder) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _ascending
                            ? Symbols.arrow_upward_rounded
                            : Symbols.arrow_downward_rounded,
                        size: 14,
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );

  List<Widget> _buildMembers() {
    if (!_canReadMembers) {
      return [
        _emptySliver(
          title: context.l10n.group_membersHidden,
          icon: Symbols.lock_rounded,
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: InputFieldShell(
                  child: TextField(
                    controller: _searchController,
                    enabled: !_loading,
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                    textAlignVertical: TextAlignVertical.center,
                    onSubmitted: (_) {
                      _searchDebounce?.cancel();
                      _loadMembers();
                    },
                    decoration: InputDecoration(
                      visualDensity: VisualDensity.standard,
                      hintText: context.l10n.group_searchMembers,
                      prefixIcon: const Icon(Symbols.search_rounded),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: context.l10n.common_clear,
                              onPressed: () {
                                _searchController.clear();
                                _onSearchChanged('');
                              },
                              icon: const Icon(Symbols.close_rounded),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SwipeDismissiblePopupMenuButton<({GroupMemberOrder? order})>(
                tooltip: context.l10n.group_sortMembers,
                enabled: !_loading,
                icon: const Icon(Symbols.sort_rounded),
                onSelected: (selection) => _sortMembers(
                  selection.order,
                  selection.order == null ||
                      selection.order == GroupMemberOrder.username,
                ),
                itemBuilder: (_) => [
                  for (final order in <GroupMemberOrder?>[
                    null,
                    ...GroupMemberOrder.values,
                  ])
                    CheckedPopupMenuItem(
                      value: (order: order),
                      checked: order == _memberOrder,
                      child: Text(_memberOrderLabel(order)),
                    ),
                ],
              ),
              if (_memberOrder != null)
                IconButton(
                  tooltip: _ascending
                      ? context.l10n.group_ascending
                      : context.l10n.group_descending,
                  onPressed: _loading
                      ? null
                      : () => _sortMembers(_memberOrder, !_ascending),
                  icon: Icon(
                    _ascending
                        ? Symbols.arrow_upward_rounded
                        : Symbols.arrow_downward_rounded,
                  ),
                ),
            ],
          ),
        ),
      ),
      if (_members.isEmpty)
        _statusSliver(
          loading: _membersLoading,
          error: _membersError,
          retry: _loadMembers,
          empty: _query.isEmpty
              ? context.l10n.common_noData
              : context.l10n.search_noResults,
        )
      else ...[
        SliverToBoxAdapter(child: _buildMemberColumns()),
        SliverList.builder(
          itemCount: _members.length,
          itemBuilder: (context, index) => SegmentedCardItem(
            index: index,
            count: _members.length,
            gap: 3,
            child: GroupMemberTile(
              position: (index: index, count: _members.length),
              user: _members[index],
              owner: _ownerIds.contains(_members[index].id),
              joinedAt: _joinedAt[_members[index].id],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: PagedListFooter(
            hasMore: _membersHaveMore,
            isLoadingMore: _membersLoading,
            isLoadMoreFailed: _membersError != null,
            onRetry: () => _loadMembers(loadMore: _membersFailedLoadMore),
          ),
        ),
      ],
    ];
  }

  String _activityLabel(GroupActivityFilter filter) => switch (filter) {
    GroupActivityFilter.posts => context.l10n.group_posts,
    GroupActivityFilter.topics => context.l10n.userProfile_tabTopics,
    GroupActivityFilter.mentions => context.l10n.group_mentions,
  };

  List<Widget> _buildActivity() {
    if (!_canReadMembers) {
      return [
        _emptySliver(
          title: context.l10n.group_activityHidden,
          icon: Symbols.lock_rounded,
        ),
      ];
    }
    final categories = {
      ...?ref.watch(categoryMapProvider).value,
      ..._activityCategories,
    };
    final categoryLabel = _categoryId == null
        ? context.l10n.group_allCategories
        : categories[_categoryId]?.name ?? '#$_categoryId';
    final topics = _activityFilter == GroupActivityFilter.topics;
    final count = topics ? _topics.length : _posts.length;
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              M3eButtonGroup<GroupActivityFilter>(
                selected: _activityFilter,
                scrollable: true,
                items: [
                  for (final filter in GroupActivityFilter.values)
                    if (filter != GroupActivityFilter.mentions ||
                        _mentionsEnabled)
                      M3eButtonGroupItem(
                        value: filter,
                        label: Text(_activityLabel(filter)),
                      ),
                ],
                onSelected: (filter) async {
                  if (_loading || _activityFilter == filter) return;
                  setState(() => _activityFilter = filter);
                  await _reloadActivityFilter();
                },
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _loading ? null : _selectCategory,
                icon: const Icon(Symbols.filter_list_rounded, size: 18),
                label: Text(
                  categoryLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      if (count == 0)
        _statusSliver(
          loading: _activityLoading,
          error: _activityError,
          retry: _loadActivity,
          empty: context.l10n.group_noActivity,
        )
      else ...[
        SliverList.builder(
          itemCount: count,
          itemBuilder: (context, index) => topics
              ? LayoutBuilder(
                  builder: (context, constraints) => buildTopicItem(
                    context: context,
                    topic: _topics[index],
                    isSelected: false,
                    onTap: () =>
                        launchContentLink(context, '/t/${_topics[index].id}'),
                    enableLongPress: true,
                    categoryMap: categories,
                    availableWidth: constraints.maxWidth,
                  ),
                )
              : GroupPostTile(
                  position: (index: index, count: count),
                  post: _posts[index],
                  categories: categories,
                ),
        ),
        SliverToBoxAdapter(
          child: PagedListFooter(
            hasMore: _activityHasMore,
            isLoadingMore: _activityLoading,
            isLoadMoreFailed: _activityError != null,
            onRetry: () => _loadActivity(loadMore: _activityFailedLoadMore),
          ),
        ),
      ],
    ];
  }

  List<Widget> _buildPermissions() => [
    if (_permissions.isEmpty)
      _statusSliver(
        loading: _permissionsLoading,
        error: _permissionsError,
        retry: _loadPermissions,
        empty: context.l10n.group_noPermissions,
      )
    else ...[
      if (_permissionsError != null)
        SliverToBoxAdapter(
          child: ErrorView(
            error: _permissionsError!,
            onRetry: _loadPermissions,
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        sliver: SliverList.builder(
          itemCount: _permissions.length,
          itemBuilder: (context, index) => SegmentedCardItem(
            index: index,
            count: _permissions.length,
            gap: 3,
            child: GroupPermissionTile(
              permission: _permissions[index],
              position: (index: index, count: _permissions.length),
            ),
          ),
        ),
      ),
    ],
  ];
}

class _GroupTabsHeader extends SliverPersistentHeaderDelegate {
  _GroupTabsHeader({required this.child, required this.height});
  final Widget child;
  final double height;
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox.expand(child: child);
  @override
  bool shouldRebuild(_GroupTabsHeader oldDelegate) =>
      oldDelegate.child != child || oldDelegate.height != height;
}
