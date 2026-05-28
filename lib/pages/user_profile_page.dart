import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../models/user.dart';
import '../models/user_action.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/time_utils.dart';
import '../widgets/common/relative_time_text.dart';
import '../utils/number_utils.dart';
import '../utils/pagination_helper.dart';
import '../services/emoji_handler.dart';
import 'package:dio/dio.dart';
import '../utils/url_helper.dart';
import '../services/app_error_handler.dart';
import '../utils/share_utils.dart';
import '../providers/preferences_provider.dart';
import '../widgets/common/flair_badge.dart';
import '../widgets/common/grain_gradient_background.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/content/discourse_html_content/discourse_html_content_widget.dart';
import '../widgets/content/collapsed_html_content.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/user/user_profile_skeleton.dart';
import '../widgets/badge/badge_ui_utils.dart';
import '../services/toast_service.dart';
import '../models/badge.dart' as badge_model;
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import 'follow_list_page.dart';
import 'image_viewer_page.dart';
import 'badge_page.dart';
import '../widgets/common/dismissible_popup_menu.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';

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

  // 订阅级别: normal / mute / ignore
  String _notificationLevel = 'normal';

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
          _notificationLevel = user.ignored == true
              ? 'ignore'
              : user.muted == true
                  ? 'mute'
                  : 'normal';
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
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
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

  /// 设置用户订阅级别
  Future<void> _setNotificationLevel(String level) async {
    if (_user == null) return;

    // 如果是 ignore，需要先选择时长
    if (level == 'ignore') {
      final expiringAt = await _showIgnoreDurationPicker();
      if (expiringAt == null) return; // 用户取消

      final oldLevel = _notificationLevel;
      setState(() => _notificationLevel = 'ignore');
      try {
        final service = ref.read(discourseServiceProvider);
        await service.updateUserNotificationLevel(
          _user!.username,
          level: 'ignore',
          expiringAt: expiringAt,
        );
        if (mounted) {
          setState(() {
            _user = _user!.copyWith(muted: false, ignored: true);
          });
          ToastService.showSuccess(S.current.userProfile_setToIgnore);
        }
      } catch (_) {
        if (mounted) setState(() => _notificationLevel = oldLevel);
      }
      return;
    }

    final oldLevel = _notificationLevel;
    setState(() => _notificationLevel = level);
    try {
      final service = ref.read(discourseServiceProvider);
      await service.updateUserNotificationLevel(_user!.username, level: level);
      if (mounted) {
        setState(() {
          _user = _user!.copyWith(
            muted: level == 'mute',
            ignored: false,
          );
        });
        final label = level == 'mute' ? S.current.userProfile_setToMute : S.current.userProfile_restored;
        ToastService.showSuccess(label);
      }
    } catch (_) {
      if (mounted) setState(() => _notificationLevel = oldLevel);
    }
  }

  /// 显示忽略时长选择弹窗，返回 expiringAt 时间字符串
  Future<String?> _showIgnoreDurationPicker() async {
    // 与 Discourse 前端 extendedDefaultTimeShortcuts 保持一致
    final now = DateTime.now();
    final weekdays = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    String formatTarget(DateTime target) {
      // 永久不显示时间
      if (target.year - now.year > 100) return '';
      final h = target.hour.toString().padLeft(2, '0');
      final m = target.minute.toString().padLeft(2, '0');
      final time = '$h:$m';
      // 同一天只显示时间
      if (target.day == now.day && target.month == now.month && target.year == now.year) {
        return time;
      }
      // 同年显示 月日 周几 时间
      if (target.year == now.year) {
        return '${S.current.time_shortDate(target.month, target.day)} ${weekdays[target.weekday]} $time';
      }
      // 跨年显示完整日期
      return '${S.current.time_fullDate(target.year, target.month, target.day)} $time';
    }

    final options = <(String, Duration)>[
      if (now.hour < 18)
        (S.current.userProfile_laterToday, Duration(hours: 18 - now.hour)),
      (S.current.userProfile_tomorrow, Duration(days: 1)),
      if (now.weekday <= DateTime.wednesday)
        (S.current.userProfile_laterThisWeek, Duration(days: DateTime.thursday - now.weekday)),
      (S.current.userProfile_nextMonday, Duration(days: (DateTime.monday - now.weekday + 7) % 7 == 0 ? 7 : (DateTime.monday - now.weekday + 7) % 7)),
      (S.current.userProfile_twoWeeks, Duration(days: 14)),
      (S.current.userProfile_nextMonth, Duration(days: 30)),
      (S.current.userProfile_twoMonths, Duration(days: 60)),
      (S.current.userProfile_threeMonths, Duration(days: 90)),
      (S.current.userProfile_fourMonths, Duration(days: 120)),
      (S.current.userProfile_sixMonths, Duration(days: 180)),
      (S.current.userProfile_oneYear, Duration(days: 365)),
      (S.current.userProfile_permanent, Duration(days: 365000)),
    ];

    return showAppBottomSheet<String>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  context.l10n.userProfile_selectIgnoreDuration,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const Divider(),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: options.map((option) {
                    final target = now.add(option.$2);
                    final desc = formatTarget(target);
                    return ListTile(
                      title: Text(option.$1),
                      trailing: desc.isNotEmpty
                          ? Text(desc, style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ))
                          : null,
                      onTap: () {
                        final expiry = DateTime.now().toUtc().add(option.$2);
                        Navigator.pop(context, expiry.toIso8601String());
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 显示用户详细信息弹窗
  void _showUserInfo() {
    if (_user == null) return;

    final hasBio = _user!.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user!.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user!.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user!.createdAt != null;
    final isSuspended = _user!.isSuspended;
    final isSilenced = _user!.isSilenced;

    if (!hasBio && !hasLocation && !hasWebsite && !hasJoinedAt && !isSuspended && !isSilenced) return;

    showAppBottomSheet(
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
                        context.l10n.common_about,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
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
                      // 封禁/禁言状态
                      if (isSuspended)
                        _buildRestrictionSection(
                          theme,
                          icon: Icons.block_rounded,
                          title: context.l10n.userProfile_suspendedStatus,
                          label: _user!.isSuspendedForever
                              ? context.l10n.userProfile_permanentlySuspended
                              : context.l10n.userProfile_suspendedUntil(TimeUtils.formatFullDate(_user!.suspendedTill)),
                          reason: _user!.suspendReason,
                          color: theme.colorScheme.error,
                        ),
                      if (isSilenced)
                        _buildRestrictionSection(
                          theme,
                          icon: Icons.mic_off_rounded,
                          title: context.l10n.userProfile_silencedStatus,
                          label: _user!.isSilencedForever
                              ? context.l10n.userProfile_permanentlySilenced
                              : context.l10n.userProfile_silencedUntil(TimeUtils.formatFullDate(_user!.silencedTill)),
                          reason: _user!.silenceReason,
                          color: Colors.orange,
                        ),

                      // 个人简介
                      if (hasBio) ...[
                        Text(
                          context.l10n.userProfile_bio,
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
                          context.l10n.userProfile_moreInfo,
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
                            context.l10n.userProfile_location,
                            _user!.location!,
                          ),

                        if (hasWebsite)
                          _buildInfoRow(
                            context,
                            Icons.link_rounded,
                            context.l10n.userProfile_website,
                            _user!.websiteName ?? _user!.website!,
                            url: _user!.website,
                            isLink: true,
                          ),

                        if (hasJoinedAt)
                          _buildInfoRow(
                            context,
                            Icons.calendar_today_rounded,
                            context.l10n.userProfile_joinDate,
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

  /// 关于弹窗中的封禁/禁言区块
  Widget _buildRestrictionSection(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String label,
    required String? reason,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (reason != null && reason.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    reason,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
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
        body: Center(child: Text('${context.l10n.common_loadFailed}: $_error')),
      );
    }

    // 计算 pinned header 高度
    final double pinnedHeaderHeight = kToolbarHeight + MediaQuery.of(context).padding.top + 36; // 36 是 TabBar 高度

    return Scaffold(
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ExtendedNestedScrollView(
          controller: _scrollController,
          pinnedHeaderSliverHeightBuilder: () => pinnedHeaderHeight,
          onlyOneScrollInBody: true,
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            _buildSliverAppBar(context, theme, currentUser),
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
      ),
    );
  }

  Widget _buildSliverAppBar(BuildContext context, ThemeData theme, User? currentUser) {
    final bgUrl = _user?.backgroundUrl;
    final hasBackground = bgUrl != null && bgUrl.isNotEmpty;
    // Standard toolbar height is usually 56.0 + status bar height
    final double pinnedHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    // 横屏时屏幕高度有限，限制 expandedHeight 不超过屏幕高度的 70%
    final screenHeight = MediaQuery.of(context).size.height;
    final double expandedHeight = 410.0.clamp(0.0, screenHeight * 0.7);

    // Check if there is any info to show (for the "About" popup)
    final hasBio = _user?.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user?.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user?.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user?.createdAt != null;
    final hasInfo = hasBio || hasLocation || hasWebsite || hasJoinedAt;

    // 检查是否是自己
    final isOwnProfile = currentUser != null && _user != null && currentUser.username == _user!.username;

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      stretch: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent, // Transparent to show FlexibleSpaceBar background
      surfaceTintColor: Colors.transparent, // Prevent M3 tint
      iconTheme: const IconThemeData(color: Colors.white),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => _openUserSearch(),
        ),
        if (_user != null && _user!.canSendPrivateMessageToUser != false)
          IconButton(
            onPressed: _openMessageDialog,
            icon: const Icon(Icons.mail_outline_rounded),
            tooltip: context.l10n.userProfile_message,
          ),
        SwipeDismissiblePopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'about':
                _showUserInfo();
              case 'share':
                _shareUser();
              case 'level_normal':
                _setNotificationLevel('normal');
              case 'level_mute':
                _setNotificationLevel('mute');
              case 'level_ignore':
                _setNotificationLevel('ignore');
            }
          },
          itemBuilder: (context) {
            final theme = Theme.of(context);
            return [
              PopupMenuItem<String>(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 20, color: theme.colorScheme.onSurface),
                    const SizedBox(width: 12),
                    Text(context.l10n.common_about),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.share_outlined, size: 20, color: theme.colorScheme.onSurface),
                    const SizedBox(width: 12),
                    Text(context.l10n.userProfile_shareUser),
                  ],
                ),
              ),
              // 非自己才显示订阅级别选项
              if (!isOwnProfile && _user != null) ...[
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'level_normal',
                  child: Row(
                    children: [
                      Icon(Icons.notifications_outlined, size: 20, color: theme.colorScheme.onSurface),
                      const SizedBox(width: 12),
                      Expanded(child: Text(context.l10n.userProfile_normal)),
                      if (_notificationLevel == 'normal')
                        Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
                    ],
                  ),
                ),
                if (_user!.canMuteUser != false)
                  PopupMenuItem<String>(
                    value: 'level_mute',
                    child: Row(
                      children: [
                        Icon(Icons.notifications_off_outlined, size: 20, color: theme.colorScheme.onSurface),
                        const SizedBox(width: 12),
                        Expanded(child: Text(context.l10n.userProfile_mute)),
                        if (_notificationLevel == 'mute')
                          Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
                      ],
                    ),
                  ),
                if (_user!.canIgnoreUser == true)
                  PopupMenuItem<String>(
                    value: 'level_ignore',
                    child: Row(
                      children: [
                        Icon(Icons.visibility_off_outlined, size: 20, color: theme.colorScheme.onSurface),
                        const SizedBox(width: 12),
                        Expanded(child: Text(context.l10n.userProfile_ignored)),
                        if (_notificationLevel == 'ignore')
                          Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
                      ],
                    ),
                  ),
              ],
            ];
          },
        ),
      ],
      // Bottom 参数承载 TabBar，并应用圆角背景，这样它会“浮”在 FlexibleSpace 背景图之上
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(36),
        child: Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: TabBar(
            controller: _tabController,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            indicatorColor: theme.colorScheme.primary,
            labelPadding: const EdgeInsets.symmetric(horizontal: 12),
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(height: 36, text: context.l10n.userProfile_tabSummary),
              Tab(height: 36, text: context.l10n.userProfile_tabActivity),
              Tab(height: 36, text: context.l10n.userProfile_tabTopics),
              Tab(height: 36, text: context.l10n.userProfile_tabReplies),
              Tab(height: 36, text: context.l10n.userProfile_tabLikes),
              Tab(height: 36, text: context.l10n.userProfile_tabReactions),
            ],
          ),
          ),
        ),
      ),
      // Use a Stack to ensure a solid black background exists BEHIND the FlexibleSpaceBar
      flexibleSpace: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final currentHeight = constraints.biggest.height;
          final t = ((currentHeight - pinnedHeight) / (expandedHeight - pinnedHeight)).clamp(0.0, 1.0);
          
          // 标题透明度：收起时显示（当 t < 0.3 时完全显示，避免半透明）
          final titleOpacity = t < 0.3 ? 1.0 : (1.0 - ((t - 0.3) / 0.7)).clamp(0.0, 1.0);
          // 内容透明度：展开时显示
          final contentOpacity = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
          
          return Stack(
            fit: StackFit.expand,
            children: [
              // ===== 层 0: 背景 - shader 动画 + 径向渐变辉光 + 图片叠加 =====
              // 用 ClipRect 裁剪溢出，内部固定为 expandedHeight，防止收起时 shader 被压扁
              Positioned.fill(
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    maxHeight: expandedHeight,
                    child: SizedBox(
                      height: expandedHeight,
                      child: const GrainGradientBackground(),
                    ),
                  ),
                ),
              ),
              if (hasBackground)
                Image(
                  image: discourseImageProvider(
                    UrlHelper.resolveUrlWithCdn(bgUrl),
                  ),
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded || frame != null) {
                      return AnimatedOpacity(
                        opacity: frame != null ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: child,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),

              // ===== 层 1: 统一压暗遮罩 - 随向上滑动变得更暗 =====
              Container(
                color: Color.lerp(
                  Colors.black.withValues(alpha:0.6), // 展开状态：默认更暗 (0.6)
                  Colors.black.withValues(alpha:0.85), // 收起状态：稍微透一点 (0.85)
                  Curves.easeOut.transform(1.0 - t), // 使用 easeOut 曲线优化滑动体验
                ),
              ),

              // ===== 层 2: 用户信息内容 - 展开时显示，收起时淡出 =====
              Positioned(
                left: 20,
                right: 20,
                bottom: 36 + 24, // TabBar 高度 + 间距
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像、姓名、操作按钮一行
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 1. 头像 radius=36，flair 大小 30，偏移 right=-7, bottom=-4
                          GestureDetector(
                            onTap: () {
                              if (_user?.getAvatarUrl() != null) {
                                final avatarUrl = _user!.getAvatarUrl(size: 360);
                                ImageViewerPage.open(
                                  context,
                                  avatarUrl,
                                  heroTag: 'user_avatar_${_user!.username}',
                                );
                              }
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              child: AvatarWithFlair(
                                flairSize: 30,
                                flairRight: -7,
                                flairBottom: -4,
                                flairUrl: _user?.flairUrl,
                                flairName: _user?.flairName,
                                flairBgColor: _user?.flairBgColor,
                                flairColor: _user?.flairColor,
                                avatar: Hero(
                                  tag: 'user_avatar_${_user?.username ?? ''}',
                                  child: SmartAvatar(
                                    imageUrl: _user?.getAvatarUrl() != null
                                        ? _user!.getAvatarUrl(size: 144)
                                        : null,
                                    radius: 36,
                                    fallbackText: _user?.username,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          
                          // 2. 姓名、身份信息
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Row 1: Name + Status
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        (_user?.name?.isNotEmpty == true) ? _user!.name! : (_user?.username ?? ''),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          shadows: [Shadow(color: Colors.black45, offset: Offset(0, 1), blurRadius: 2)],
                                        ),
                                      ),
                                    ),
                                    if (_user?.status != null) ...[
                                      const SizedBox(width: 8),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: _buildStatusEmoji(_user!.status!),
                                      ),
                                    ],
                                  ],
                                ),
                                
                                // Row 2: Username
                                if (_user?.username != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                                    child: Text(
                                       '@${_user?.username}',
                                       style: TextStyle(color: Colors.white.withValues(alpha:0.85), fontSize: 13),
                                    ),
                                  )
                                else
                                  const SizedBox(height: 6), // 占位

                                // Row 3: Level Badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha:0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _getTrustLevelLabel(_user?.trustLevel ?? 0),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // 3. 操作按钮 (关注)
                          if (_user != null && !isOwnProfile) ...[
                            const SizedBox(width: 12),
                            _buildFollowButton(isOwnProfile),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      // 封禁/禁言状态 与 个人简介 互斥显示（与 Discourse 前端一致）
                      if (_user!.isSuspended || _user!.isSilenced) ...[
                        GestureDetector(
                          onTap: _showUserInfo,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 封禁提示
                              if (_user!.isSuspended) ...[
                                _buildRestrictionBanner(
                                  icon: Icons.block_rounded,
                                  label: _user!.isSuspendedForever
                                      ? context.l10n.userProfile_suspendedBannerForever
                                      : context.l10n.userProfile_suspendedBannerUntil(TimeUtils.formatFullDate(_user!.suspendedTill)),
                                  reason: _user!.suspendReason,
                                  color: Colors.redAccent,
                                ),
                                if (_user!.isSilenced)
                                  const SizedBox(height: 8),
                              ],
                              // 禁言提示
                              if (_user!.isSilenced)
                                _buildRestrictionBanner(
                                  icon: Icons.mic_off_rounded,
                                  label: _user!.isSilencedForever
                                      ? context.l10n.userProfile_silencedBannerForever
                                      : context.l10n.userProfile_silencedBannerUntil(TimeUtils.formatFullDate(_user!.silencedTill)),
                                  reason: _user!.silenceReason,
                                  color: Colors.orangeAccent,
                                ),
                            ],
                          ),
                        ),
                      ] else ...[
                        // 个人简介（非封禁/禁言状态时显示）
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: hasInfo ? _showUserInfo : null,
                          child: Container(
                            height: 54,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha:0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: hasBio
                                      ? CollapsedHtmlContent(
                                          html: _user!.bio!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          textStyle: TextStyle(
                                            color: Colors.white.withValues(alpha:0.9),
                                            fontSize: 14,
                                            height: 1.3,
                                          ),
                                        )
                                      : Text(
                                          context.l10n.userProfile_noBio,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha:0.5),
                                            fontSize: 14,
                                            height: 1.3,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                ),
                                if (hasInfo) ...[
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.chevron_right,
                                    size: 16,
                                    color: Colors.white.withValues(alpha:0.6),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],

                      // Stats
                      const SizedBox(height: 16),
                      if (_summary != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 第一行：关注、粉丝
                            if (_user?.totalFollowing != null || _user?.totalFollowers != null)
                              Wrap(
                                spacing: 16,
                                children: [
                                  if (_user?.totalFollowing != null)
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => FollowListPage(
                                            username: widget.username,
                                            isFollowing: true,
                                          ),
                                        ),
                                      ),
                                      child: _buildStatSlot(NumberUtils.formatCount(_user!.totalFollowing!), context.l10n.userProfile_following, _user!.totalFollowing!),
                                    ),
                                  if (_user?.totalFollowers != null)
                                    GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => FollowListPage(
                                            username: widget.username,
                                            isFollowing: false,
                                          ),
                                        ),
                                      ),
                                      child: _buildStatSlot(NumberUtils.formatCount(_user!.totalFollowers!), context.l10n.userProfile_followers, _user!.totalFollowers!),
                                    ),
                                ],
                              ),
                            // 第二行：获赞、访问、话题、回复
                            if (_user?.totalFollowing != null || _user?.totalFollowers != null)
                              const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              children: [
                                _buildStatSlot(NumberUtils.formatCount(_summary!.likesReceived), context.l10n.userProfile_statsLikes, _summary!.likesReceived),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.daysVisited), context.l10n.userProfile_statsVisits, _summary!.daysVisited),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.topicCount), context.l10n.userProfile_statsTopics, _summary!.topicCount),
                                _buildStatSlot(NumberUtils.formatCount(_summary!.postCount), context.l10n.userProfile_statsReplies, _summary!.postCount),
                              ],
                            ),
                          ],
                        ),
                      
                      // 最近活动时间
                      if (_user?.lastPostedAt != null || _user?.lastSeenAt != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha:0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.flash_on_rounded, size: 12, color: Colors.white70),
                              const SizedBox(width: 4),
                              RelativeTimeText(
                                dateTime: _user?.lastSeenAt ?? _user!.lastPostedAt!,
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // ===== 层 3: 收起时的标题栏内容 - 收起时显示，点击展开 =====
              Positioned(
                left: 60 + MediaQuery.of(context).padding.left, // 横屏时需加上左侧安全区
                right: 48 + MediaQuery.of(context).padding.right, // 横屏时需加上右侧安全区
                bottom: 14 + 36, // 调整位置适应 TabBar (36是TabBar高度)
                child: GestureDetector(
                  onTap: titleOpacity > 0.5 ? () {
                    _scrollController.animateTo(
                      0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  } : null,
                  behavior: HitTestBehavior.opaque,
                  child: Opacity(
                    opacity: titleOpacity,
                    child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 头像 radius=16，flair 大小 14，偏移 right=-3, bottom=-1
                      AvatarWithFlair(
                        flairSize: 14,
                        flairRight: -3,
                        flairBottom: -1,
                        flairUrl: _user?.flairUrl,
                        flairName: _user?.flairName,
                        flairBgColor: _user?.flairBgColor,
                        flairColor: _user?.flairColor,
                        avatar: SmartAvatar(
                          imageUrl: _user?.getAvatarUrl() != null
                              ? _user!.getAvatarUrl(size: 64)
                              : null,
                          radius: 16,
                          fallbackText: _user?.username,
                          border: Border.all(color: Colors.white70, width: 1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          (_user?.name?.isNotEmpty == true) ? _user!.name! : (_user?.username ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                ),
              ),

              // 移除之前的所有伪装层
            ],
          );
        }
      ),
    );
  }

  Widget _buildStatSlot(String value, String label, int rawValue) {
    return Tooltip(
      message: '$rawValue',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha:0.7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowButton(bool isOwnProfile) {
    if (_user == null || _user!.canFollow != true || isOwnProfile) {
      return const SizedBox.shrink();
    }

    return _isFollowLoading
        ? Container(
            width: 32,
            height: 32,
            padding: const EdgeInsets.all(8),
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : TextButton.icon(
            onPressed: _toggleFollow,
            icon: Icon(
              _isFollowed ? Icons.check_rounded : Icons.add_rounded,
              size: 16,
            ),
            label: Text(_isFollowed ? context.l10n.userProfile_followed : context.l10n.userProfile_follow),
            style: TextButton.styleFrom(
              backgroundColor: _isFollowed ? Colors.white.withValues(alpha:0.15) : Colors.white,
              foregroundColor: _isFollowed ? Colors.white : Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: _isFollowed ? const BorderSide(color: Colors.white38) : BorderSide.none,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          );
  }

  Widget _buildRestrictionBanner({
    required IconData icon,
    required String label,
    required String? reason,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusEmoji(UserStatus status) {
    final emoji = status.emoji;
    if (emoji == null || emoji.isEmpty) return const SizedBox.shrink();

    final isEmojiName = emoji.contains(RegExp(r'[a-zA-Z0-9_]')) && !emoji.contains(RegExp(r'[^\x00-\x7F]'));

    if (isEmojiName) {
      final cleanName = emoji.replaceAll(':', '');
      final emojiUrl = _getEmojiUrl(cleanName);

      return Image(
        image: emojiImageProvider(emojiUrl),
        width: 18,
        height: 18,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }

    return Text(
      emoji,
      style: const TextStyle(fontSize: 16),
    );
  }

  Widget _buildActionList(String filter) {
    // 总结 tab
    if (filter == 'summary') {
      return _buildSummaryTab();
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
            Text(context.l10n.userProfile_noContent, style: TextStyle(color: Colors.grey[600])),
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
            return _buildActionItem(actions[index]);
          },
        ),
      ),
    );
  }

  Widget _buildSummaryTab() {
    if (_summary == null) {
      return const UserActionListSkeleton();
    }

    final theme = Theme.of(context);
    final summary = _summary!;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // 热门话题
        if (summary.topics.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.article_rounded, context.l10n.userProfile_topTopics),
          const SizedBox(height: 8),
          ...summary.topics.map((topic) => _buildSummaryTopicItem(theme, topic)),
          const SizedBox(height: 20),
        ],

        // 热门回复
        if (summary.replies.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.chat_bubble_rounded, context.l10n.userProfile_topReplies),
          const SizedBox(height: 8),
          ...summary.replies.map((reply) => _buildSummaryReplyItem(theme, reply)),
          const SizedBox(height: 20),
        ],

        // 热门链接
        if (summary.links.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.link_rounded, context.l10n.userProfile_topLinks),
          const SizedBox(height: 8),
          ...summary.links.map((link) => _buildSummaryLinkItem(theme, link)),
          const SizedBox(height: 20),
        ],

        // 最多回复至
        if (summary.mostRepliedToUsers.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.reply_rounded, context.l10n.userProfile_mostRepliedTo),
          const SizedBox(height: 8),
          _buildUserChips(theme, summary.mostRepliedToUsers),
          const SizedBox(height: 20),
        ],

        // 被谁赞的最多
        if (summary.mostLikedByUsers.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.favorite_rounded, context.l10n.userProfile_mostLikedBy),
          const SizedBox(height: 8),
          _buildUserChips(theme, summary.mostLikedByUsers),
          const SizedBox(height: 20),
        ],

        // 赞最多
        if (summary.mostLikedUsers.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.thumb_up_rounded, context.l10n.userProfile_mostLiked),
          const SizedBox(height: 8),
          _buildUserChips(theme, summary.mostLikedUsers),
          const SizedBox(height: 20),
        ],

        // 热门类别
        if (summary.topCategories.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.category_rounded, context.l10n.userProfile_topCategories),
          const SizedBox(height: 8),
          ...summary.topCategories.map((cat) => _buildSummaryCategoryItem(theme, cat)),
          const SizedBox(height: 20),
        ],

        // 热门徽章
        if (summary.badges.isNotEmpty) ...[
          _buildSectionHeader(theme, Icons.military_tech_rounded, context.l10n.userProfile_topBadges),
          const SizedBox(height: 8),
          _buildBadgeChips(theme, summary.badges),
          const SizedBox(height: 20),
        ],

        // 若所有列表都为空
        if (summary.topics.isEmpty &&
            summary.replies.isEmpty &&
            summary.links.isEmpty &&
            summary.mostRepliedToUsers.isEmpty &&
            summary.mostLikedByUsers.isEmpty &&
            summary.mostLikedUsers.isEmpty &&
            summary.topCategories.isEmpty &&
            summary.badges.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Column(
                children: [
                  Icon(Icons.summarize_outlined, size: 48, color: Colors.grey[400]),
                  const SizedBox(height: 8),
                  Text(context.l10n.userProfile_noSummary, style: TextStyle(color: Colors.grey[600])),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSectionHeader(ThemeData theme, IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTopicItem(ThemeData theme, SummaryTopic topic) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(topicId: topic.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  topic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (topic.likeCount > 0) ...[
                const SizedBox(width: 8),
                Icon(Icons.favorite_rounded, size: 14, color: theme.colorScheme.outline),
                const SizedBox(width: 2),
                Text(
                  '${topic.likeCount}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryReplyItem(ThemeData theme, SummaryReply reply) {
    final topic = reply.topic;
    final targetTopicId = topic?.id ?? reply.topicId;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: targetTopicId != null
            ? () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TopicDetailPage(
                      topicId: targetTopicId,
                      scrollToPostNumber: reply.postNumber,
                    ),
                  ),
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  topic?.title ?? context.l10n.userProfile_topicHash(targetTopicId.toString()),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (reply.likeCount > 0) ...[
                const SizedBox(width: 8),
                Icon(Icons.favorite_rounded, size: 14, color: theme.colorScheme.outline),
                const SizedBox(width: 2),
                Text(
                  '${reply.likeCount}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryLinkItem(ThemeData theme, SummaryLink link) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (link.topic != null) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TopicDetailPage(
                  topicId: link.topic!.id,
                  scrollToPostNumber: link.postNumber,
                ),
              ),
            );
          } else {
            launchUrl(Uri.parse(link.url));
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.open_in_new_rounded, size: 16, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      link.title ?? link.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    if (link.topic != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        link.topic!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (link.clicks > 0) ...[
                const SizedBox(width: 8),
                Text(
                  context.l10n.userProfile_linkClicks(link.clicks),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserChips(ThemeData theme, List<SummaryUserWithCount> users) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: users.map((user) => InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserProfilePage(username: user.username),
          ),
        ),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SmartAvatar(
                imageUrl: user.getAvatarUrl(size: 48),
                radius: 12,
                fallbackText: user.username,
              ),
              const SizedBox(width: 6),
              Text(
                user.name?.isNotEmpty == true ? user.name! : user.username,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${user.count}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      )).toList(),
    );
  }

  Widget _buildSummaryCategoryItem(ThemeData theme, SummaryCategory cat) {
    final color = cat.color != null
        ? Color(int.parse('FF${cat.color}', radix: 16))
        : theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                cat.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              context.l10n.userProfile_catTopicCount(cat.topicCount),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              context.l10n.userProfile_catPostCount(cat.postCount),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadgeChips(ThemeData theme, List<badge_model.Badge> badges) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: badges.map((badge) {
        final badgeType = badge.badgeType;
        final color = BadgeUIUtils.getBadgeColor(context, badgeType);

        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BadgePage(badgeId: badge.id),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              gradient: BadgeUIUtils.getBadgeGradient(context, badgeType),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: color.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FaIcon(
                  BadgeUIUtils.getBadgeIcon(badgeType),
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 6),
                Text(
                  badge.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
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
            Text(context.l10n.userProfile_noReactions, style: TextStyle(color: Colors.grey[600])),
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
            return _buildReactionItem(reactions[index]);
          },
        ),
      ),
    );
  }

  Widget _buildActionItem(UserAction action) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: action.topicId,
              scrollToPostNumber: action.postNumber,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：动作类型和时间
              Row(
                children: [
                  Icon(
                    _getActionIcon(action.actionType),
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getActionLabel(action.actionType),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (action.actingAt != null)
                    RelativeTimeText(
                      dateTime: action.actingAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              
              // 标题
              Text(
                action.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              
              // 摘要
              if (action.excerpt != null && action.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  action.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 获取 emoji 图片 URL（未加载完成时返回空字符串，由 errorBuilder 处理）
  String _getEmojiUrl(String emojiName) {
    return EmojiHandler().getEmojiUrl(emojiName);
  }

  Widget _buildReactionItem(UserReaction reaction) {
    final theme = Theme.of(context);
    final emojiUrl = reaction.reactionValue != null
        ? _getEmojiUrl(reaction.reactionValue!)
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: reaction.topicId,
              scrollToPostNumber: reaction.postNumber,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：回应 emoji 和时间
              Row(
                children: [
                  if (emojiUrl != null)
                    Image(
                      image: emojiImageProvider(emojiUrl),
                      width: 20,
                      height: 20,
                      errorBuilder: (_, _, _) => const Icon(Icons.emoji_emotions, size: 20),
                    )
                  else
                    const Icon(Icons.emoji_emotions, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.userProfile_reacted,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (reaction.createdAt != null)
                    RelativeTimeText(
                      dateTime: reaction.createdAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 话题标题
              if (reaction.topicTitle != null && reaction.topicTitle!.isNotEmpty)
                Text(
                  reaction.topicTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),

              // 帖子内容摘要
              if (reaction.excerpt != null && reaction.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reaction.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _getActionIcon(int? type) {
    switch (type) {
      case UserActionType.like:
        return Icons.favorite_rounded;
      case UserActionType.wasLiked:
        return Icons.favorite_border_rounded;
      case UserActionType.newTopic:
        return Icons.article_rounded;
      case UserActionType.reply:
        return Icons.chat_bubble_rounded;
      default:
        return Icons.history_rounded;
    }
  }

  String _getTrustLevelLabel(int level) {
    switch (level) {
      case 0:
        return S.current.user_trustLevel0;
      case 1:
        return S.current.user_trustLevel1;
      case 2:
        return S.current.user_trustLevel2;
      case 3:
        return S.current.user_trustLevel3;
      case 4:
        return S.current.user_trustLevel4;
      default:
        return S.current.user_trustLevelUnknown(level);
    }
  }

  String _getActionLabel(int? type) {
    switch (type) {
      case UserActionType.like:
        return S.current.userProfile_actionLike;
      case UserActionType.wasLiked:
        return S.current.userProfile_actionLiked;
      case UserActionType.newTopic:
        return S.current.userProfile_actionCreatedTopic;
      case UserActionType.reply:
        return S.current.userProfile_actionReplied;
      default:
        return S.current.userProfile_actionDefault;
    }
  }
}
