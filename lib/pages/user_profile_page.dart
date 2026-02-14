import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../models/user.dart';
import '../models/user_action.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/time_utils.dart';
import '../utils/number_utils.dart';
import '../utils/pagination_helper.dart';
import '../utils/url_helper.dart';
import '../utils/share_utils.dart';
import '../providers/preferences_provider.dart';
import '../widgets/common/flair_badge.dart';
import '../widgets/common/animated_gradient_background.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/common/user_status_helpers.dart';
import '../widgets/content/discourse_html_content/discourse_html_content_widget.dart';
import '../widgets/content/collapsed_html_content.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/user/user_profile_skeleton.dart';
import 'search_page.dart';
import 'follow_list_page.dart';
import 'image_viewer_page.dart';
import '../widgets/user/user_profile_summary_tab.dart';
import '../widgets/user/user_profile_action_item.dart';

part 'user_profile_page/_sliver_app_bar.dart';

/// 用户个人页
class UserProfilePage extends ConsumerStatefulWidget {
  final String username;

  const UserProfilePage({super.key, required this.username});

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  User? _user;
  UserSummary? _summary;
  bool _isLoading = true;
  String? _error;

  // 关注状态
  bool _isFollowed = false;
  bool _isFollowLoading = false;

  // 各 tab 的数据（key 为 filter 字符串）
  final Map<String, List<UserAction>> _actionsCache = {};
  final Map<String, bool> _hasMoreCache = {};
  final Map<String, bool> _loadingCache = {};

  // 回应列表单独缓存
  List<UserReaction>? _reactionsCache;
  bool _reactionsHasMore = true;
  bool _reactionsLoading = false;

  // tab 对应的 filter: summary=总结, 4,5=全部(话题+回复), 4=话题, 5=回复, 1=点赞, reactions=回应
  static const List<String> _tabFilters = ['summary', '4,5', '4', '5', '1', 'reactions'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(_onTabChanged);
    // 预先为所有 tab 设置 loading 状态，避免切换时闪现空状态
    for (final filter in _tabFilters) {
      if (filter == 'summary') {
        // 总结 tab 数据随 _summary 加载，无需单独标记
      } else if (filter == 'reactions') {
        _reactionsLoading = true;
      } else {
        _loadingCache[filter] = true;
      }
    }
    _loadUser();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final filter = _tabFilters[_tabController.index];
      if (filter == 'summary') {
        // 总结 tab - 数据随用户信息一起加载
      } else if (filter == 'reactions') {
        // 回应列表
        if (_reactionsCache == null) {
          _loadReactions();
        }
      } else if (!_actionsCache.containsKey(filter)) {
        _loadActions(filter);
      }
    }
  }

  Future<void> _loadUser() async {
    try {
      final service = ref.read(discourseServiceProvider);
      // 并行加载用户基本信息和统计数据
      final results = await Future.wait([
        service.getUser(widget.username),
        service.getUserSummary(widget.username),
      ]);

      if (mounted) {
        final user = results[0] as User;
        setState(() {
          _user = user;
          _summary = results[1] as UserSummary;
          _isFollowed = user.isFollowed ?? false;
          _isLoading = false;
        });
        // 总结 tab 数据已从 _summary 获取，无需额外加载
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// 切换关注状态
  Future<void> _toggleFollow() async {
    if (_user == null || _isFollowLoading) return;

    setState(() => _isFollowLoading = true);

    try {
      final service = ref.read(discourseServiceProvider);
      if (_isFollowed) {
        await service.unfollowUser(_user!.username);
      } else {
        await service.followUser(_user!.username);
      }

      if (mounted) {
        setState(() {
          _isFollowed = !_isFollowed;
        });
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isFollowLoading = false);
      }
    }
  }

  /// 打开私信对话框
  void _openMessageDialog() {
    if (_user == null) return;

    showReplySheet(
      context: context,
      targetUsername: _user!.username,
    );
  }

  /// 打开用户内容搜索
  void _openUserSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(initialQuery: '@${widget.username}'),
      ),
    );
  }

  /// 分享用户
  void _shareUser() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/u/${widget.username}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
    SharePlus.instance.share(ShareParams(text: url));
  }

  /// 显示用户详细信息弹窗
  void _showUserInfo() {
    if (_user == null) return;

    final hasBio = _user!.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user!.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user!.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user!.createdAt != null;

    if (!hasBio && !hasLocation && !hasWebsite && !hasJoinedAt) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          final theme = Theme.of(context);
          return Container(
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha:0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                // 拖动指示器
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                
                // 标题栏
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: Row(
                    children: [
                      Text(
                        '关于',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      // 如果需要可以添加右上角操作按钮
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                
                // 内容
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                    children: [
                      // 个人简介
                      if (hasBio) ...[
                        Text(
                          '个人简介',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        DiscourseHtmlContent(
                          html: _user!.bio!,
                          textStyle: theme.textTheme.bodyLarge?.copyWith(
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],

                      // 其他信息列表
                      if (hasLocation || hasWebsite || hasJoinedAt) ...[
                        Text(
                          '更多信息',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        if (hasLocation)
                          _buildInfoRow(
                            context,
                            Icons.location_on_outlined,
                            '位置',
                            _user!.location!,
                          ),
                        
                        if (hasWebsite)
                          _buildInfoRow(
                            context,
                            Icons.link_rounded,
                            '网站',
                            _user!.websiteName ?? _user!.website!,
                            url: _user!.website,
                            isLink: true,
                          ),
                        
                        if (hasJoinedAt)
                          _buildInfoRow(
                            context,
                            Icons.calendar_today_rounded,
                            '加入时间',
                            TimeUtils.formatFullDate(_user!.createdAt),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, IconData icon, String label, String value, {String? url, bool isLink = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: isLink && url != null ? () => launchUrl(Uri.parse(url)) : null,
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isLink ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      decoration: isLink ? TextDecoration.underline : null,
                      decorationColor: theme.colorScheme.primary.withValues(alpha:0.3),
                    ),
                  ),
                ],
              ),
            ),
            if (isLink)
              Icon(
                Icons.open_in_new_rounded,
                size: 16,
                color: theme.colorScheme.outline.withValues(alpha:0.5),
              ),
          ],
        ),
      ),
    );
  }

  /// 用户动作分页助手
  static final _actionsPaginationHelper = PaginationHelpers.forList<UserAction>(
    keyExtractor: (a) => '${a.topicId}_${a.postNumber}_${a.actionType}',
    expectedPageSize: 30,
  );

  /// 用户回应分页助手（游标分页）
  static final _reactionsPaginationHelper = PaginationHelpers.forList<UserReaction>(
    keyExtractor: (r) => r.id,
    expectedPageSize: 20,
  );

  Future<void> _loadActions(String filter, {bool loadMore = false}) async {
    // 如果已有数据且正在加载，跳过（防止重复加载更多）
    if (_loadingCache[filter] == true && _actionsCache.containsKey(filter)) return;

    setState(() => _loadingCache[filter] = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final offset = loadMore ? (_actionsCache[filter]?.length ?? 0) : 0;
      final response = await service.getUserActions(
        widget.username,
        filter: filter,
        offset: offset,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserAction>(items: _actionsCache[filter] ?? []);
            final result = _actionsPaginationHelper.processLoadMore(
              currentState,
              PaginationResult(items: response.actions, expectedPageSize: 30),
            );
            _actionsCache[filter] = result.items;
            _hasMoreCache[filter] = result.hasMore;
          } else {
            final result = _actionsPaginationHelper.processRefresh(
              PaginationResult(items: response.actions, expectedPageSize: 30),
            );
            _actionsCache[filter] = result.items;
            _hasMoreCache[filter] = result.hasMore;
          }
          _loadingCache[filter] = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingCache[filter] = false);
      }
    }
  }

  Future<void> _loadReactions({bool loadMore = false}) async {
    if (_reactionsLoading && _reactionsCache != null) return;

    setState(() => _reactionsLoading = true);

    try {
      final service = ref.read(discourseServiceProvider);
      final beforeId = loadMore && _reactionsCache != null && _reactionsCache!.isNotEmpty
          ? _reactionsCache!.last.id
          : null;
      final response = await service.getUserReactions(widget.username, beforeReactionUserId: beforeId);

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserReaction>(items: _reactionsCache ?? []);
            final result = _reactionsPaginationHelper.processLoadMore(
              currentState,
              PaginationResult(items: response.reactions, expectedPageSize: 20),
            );
            _reactionsCache = result.items;
            _reactionsHasMore = result.hasMore;
          } else {
            final result = _reactionsPaginationHelper.processRefresh(
              PaginationResult(items: response.reactions, expectedPageSize: 20),
            );
            _reactionsCache = result.items;
            _reactionsHasMore = result.hasMore;
          }
          _reactionsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _reactionsLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_isLoading) {
      return const UserProfileSkeleton();
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.username)),
        body: Center(child: Text('加载失败: $_error')),
      );
    }

    // 计算 pinned header 高度
    final double pinnedHeaderHeight = kToolbarHeight + MediaQuery.of(context).padding.top + 36; // 36 是 TabBar 高度

    return Scaffold(
      body: ExtendedNestedScrollView(
        controller: _scrollController,
        pinnedHeaderSliverHeightBuilder: () => pinnedHeaderHeight,
        onlyOneScrollInBody: true,
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          buildSliverAppBar(context, theme, currentUser),
        ],
        body: TabBarView(
          controller: _tabController,
          children: _tabFilters.asMap().entries.map((entry) {
            final index = entry.key;
            final filter = entry.value;
            return ExtendedVisibilityDetector(
              uniqueKey: Key('tab_$index'),
              child: _buildActionList(filter),
            );
          }).toList(),
        ),
      ),
    );
  }


  Widget _buildActionList(String filter) {
    // 总结 tab
    if (filter == 'summary') {
      return _summary == null
          ? const UserActionListSkeleton()
          : UserProfileSummaryTab(
              summary: _summary!,
              onUserTap: (username) => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => UserProfilePage(username: username)),
              ),
            );
    }
    // 回应列表使用单独的逻辑
    if (filter == 'reactions') {
      return _buildReactionList();
    }

    final actions = _actionsCache[filter];
    final isLoading = _loadingCache[filter] == true;
    final hasMore = _hasMoreCache[filter] ?? true;

    // 优先检查 loading 状态
    if (isLoading && actions == null) {
      return const UserActionListSkeleton();
    }

    // 空状态
    if (actions == null || actions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text('暂无内容', style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200 &&
            hasMore &&
            !isLoading) {
          _loadActions(filter, loadMore: true);
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => _loadActions(filter),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: actions.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == actions.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return UserActionItem(action: actions[index]);
          },
        ),
      ),
    );
  }

  Widget _buildReactionList() {
    final reactions = _reactionsCache;
    final isLoading = _reactionsLoading;
    final hasMore = _reactionsHasMore;

    // 优先检查 loading 状态
    if (isLoading && reactions == null) {
      return const UserActionListSkeleton();
    }

    // 空状态
    if (reactions == null || reactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.emoji_emotions_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text('暂无回应', style: TextStyle(color: Colors.grey[600])),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200 &&
            hasMore &&
            !isLoading) {
          _loadReactions(loadMore: true);
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => _loadReactions(),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: reactions.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == reactions.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return UserReactionItem(reaction: reactions[index]);
          },
        ),
      ),
    );
  }
}
