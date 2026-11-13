import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import '../models/user.dart';
import '../models/user_action.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/time_utils.dart';
import '../utils/number_utils.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/pagination_helper.dart';
import '../services/emoji_handler.dart';

import 'package:dio/dio.dart';

import '../utils/category_navigation.dart';
import '../services/app_error_handler.dart';
import '../utils/share_utils.dart';
import '../providers/preferences_provider.dart';
import '../providers/message_bus/session_channel_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../utils/platform_utils.dart';
import '../utils/responsive.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/pane_projection_back_scope.dart';
import 'topics_screen.dart' show PaneContentWidget;
import '../widgets/common/flair_badge.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/content/collapsed_html_content.dart';
import '../utils/fluxdo_render_callbacks.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/user/user_profile_skeleton.dart';
import '../widgets/user/user_profile_header.dart';
import '../widgets/user/activity_post_card.dart';
import '../services/preloaded_data_service.dart';
import '../widgets/user/ignore_duration_picker.dart';
import '../widgets/common/morphing_dialog_anchor.dart';
import '../widgets/topic/topic_preview_dialog.dart';
import '../services/topic_preview_preloader.dart';
import '../widgets/post/post_boost/boost_content.dart';
import '../widgets/badge/badge_ui_utils.dart';
import '../services/toast_service.dart';
import '../models/badge.dart' as badge_model;
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import 'follow_list_page.dart';
import 'image_viewer_page.dart';
import 'badge_page.dart';
import 'group_page.dart';
import 'chat/channel/chat_channel_page.dart';
import 'forum_preferences/forum_preferences_page.dart';

import 'package:common_ui/common_ui.dart';

import '../l10n/s.dart';
import '../widgets/common/hero_image.dart';
import '../theme/app_colors.dart';
import '../utils/color_utils.dart';

/// 用户个人页
/// 头像的展示方式:方形账号是 cover 裁切 + 圆角,圆形账号走 circular。
///
/// 一处给出,同时约束源端与 openViewer 两侧参数(见 ViewerSourceStyle)——
/// 此前两处不同步:源端 borderRadius 12 而 openViewer 传 heroSourceRadius 8。
ViewerSourceStyle _avatarStyle({
  required bool isSquare,
  required double radius,
}) => isSquare
    ? ViewerSourceStyle.cover(radius: radius)
    : const ViewerSourceStyle.circular();

class UserProfilePage extends ConsumerStatefulWidget {
  final String username;

  /// 平行视界嵌入模式：AppBar 用 [onEmbeddedBack] 关闭当前层，而不是
  /// Navigator pop（嵌入面板不在 Navigator 路由栈里）。
  final bool embeddedMode;
  final VoidCallback? onEmbeddedBack;

  /// 宿主 tab 是否活跃(嵌入模式下用于快捷键注册失活:IndexedStack
  /// 常驻页共享根路由,非活跃 tab 的注册会截胡活跃 tab 的按键)。
  final bool parentActive;

  const UserProfilePage({
    super.key,
    required this.username,
    this.embeddedMode = false,
    this.onEmbeddedBack,
    this.parentActive = true,
  });

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  late final AnimationController _pinnedActionProgress;
  bool _actionsPinned = false;
  double? _pendingPinnedActionProgress;
  final ValueNotifier<double> _pullExtent = ValueNotifier(0);
  User? _user;
  UserSummary? _summary;
  bool _summaryLoading = false;
  Object? _summaryError;
  StackTrace? _summaryErrorStack;
  List<badge_model.UserBadge>? _badges;
  bool _badgesLoading = false;
  Object? _badgesError;
  StackTrace? _badgesErrorStack;
  String? _renamedUsername;
  String get _username => _renamedUsername ?? widget.username;
  int? _savingBadgeId;
  String _activityFilter = 'all';
  int _activeTabIndex = 0;
  bool _isLoading = true;
  Object? _error;
  StackTrace? _errorStack;

  // 关注状态
  bool _isFollowed = false;
  bool _isFollowLoading = false;

  /// 本资料页最近一次从列表压栈打开的话题 ID——用来判断栈顶是不是"我
  /// 自己上次点开的那个"，只有这种情况下才能安全替换（否则会把资料页
  /// 这一层本身，或者别的来源压上去的层，给顶掉）。
  int? _lastOpenedTopicId;

  /// 全屏形态自己的平行视界栈(按 username 隔离,叠开多个资料页互不
  /// 串)。嵌入形态不用——压宿主的栈。
  SelectedTopicProvider get _ownPaneProvider =>
      selectedUserProfilePaneProvider(_username);

  void _openTopic({
    required int topicId,
    String? initialTitle,
    int? scrollToPostNumber,
  }) {
    final stackProvider = EmbeddedStackScope.maybeOf(context);
    if (stackProvider != null) {
      ref.read(activePaneProvider.notifier).state = ActivePane.detail;
      final container = ProviderScope.containerOf(context, listen: false);
      final notifier = container.read(stackProvider.notifier);
      if (EmbeddedStackScope.isTruncating(context)) {
        // 这份资料页是 master 面板的"上一层预览"——点列表里的话题永远
        // 是"替换右边正显示的那层"，跟本页自己是不是压过东西无关。
        notifier.pushTruncating(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
        );
        _lastOpenedTopicId = topicId;
        return;
      }
      final stack = container.read(stackProvider).stack;
      final top = stack.isEmpty ? null : stack.last;
      // 资料页的话题/回复等列表点开话题：语义是"逛列表换一项"，用替换
      // 而不是一直压栈——但只有栈顶确实还是"我上次自己压的那个"才能
      // 替换，否则会误伤资料页这一层本身，或者别的来源压上去的层。
      if (_lastOpenedTopicId != null &&
          top != null &&
          top.kind == PaneKind.topic &&
          top.topicId == _lastOpenedTopicId) {
        notifier.replaceTop(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
        );
      } else {
        notifier.push(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
        );
      }
      _lastOpenedTopicId = topicId;
      return;
    }

    // 全屏形态:本页自己是平行视界宿主——宽屏点话题进右栏(select
    // 换一项语义),窄屏真路由 push(原生转场;缩窄时右栏内容自动
    // 转投影)。
    if (MasterDetailLayout.canShowBothPanesFor(context)) {
      ref.read(activePaneProvider.notifier).state = ActivePane.detail;
      ref
          .read(_ownPaneProvider.notifier)
          .select(
            topicId: topicId,
            initialTitle: initialTitle,
            scrollToPostNumber: scrollToPostNumber,
          );
      return;
    }

    final restoreScope = FullScreenPaneRestoreScope.maybeOf(context);
    if (restoreScope != null) {
      Navigator.of(context).push(
        InteractionPageRoute(
          builder: (_) => TopicDetailPage(
            topicId: topicId,
            initialTitle: initialTitle,
            scrollToPostNumber: scrollToPostNumber,
            autoSwitchToMasterDetail: true,
            stackProvider: restoreScope.stackProvider,
            restoreParentPaneStack: restoreScope.restoreCurrentPane,
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      InteractionPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topicId,
          initialTitle: initialTitle,
          scrollToPostNumber: scrollToPostNumber,
        ),
      ),
    );
  }

  // 订阅级别: normal / mute / ignore
  String _notificationLevel = 'normal';

  // 各 tab 的数据（key 为 filter 字符串）
  final Map<String, List<UserAction>> _actionsCache = {};
  final Map<String, bool> _hasMoreCache = {};
  final Map<String, bool> _loadingCache = {};
  final Map<String, bool> _loadMoreFailedCache = {};
  final Map<String, Object> _actionErrors = {};
  final Map<String, LoadMoreCoordinator> _actionLoadMoreCoordinators = {};

  // 回应列表单独缓存
  List<UserReaction>? _reactionsCache;
  bool _reactionsHasMore = true;
  bool _reactionsLoading = false;
  bool _reactionsLoadMoreFailed = false;
  final LoadMoreCoordinator _reactionsLoadMoreCoordinator =
      LoadMoreCoordinator();

  // Boost 列表单独缓存（游标分页）
  List<UserBoost>? _boostsCache;
  bool _boostsHasMore = true;
  bool _boostsLoading = false;
  bool _boostsLoadMoreFailed = false;
  final LoadMoreCoordinator _boostsLoadMoreCoordinator = LoadMoreCoordinator();

  // 投票话题列表单独缓存（标准话题列表 page 分页）
  List<Topic>? _votesCache;
  bool _votesHasMore = true;
  bool _votesLoading = false;
  bool _votesLoadMoreFailed = false;
  int _votesPage = 0;
  final LoadMoreCoordinator _votesLoadMoreCoordinator = LoadMoreCoordinator();

  // 已解决列表单独缓存（offset 分页）
  List<SolvedPost>? _solvedCache;
  bool _solvedHasMore = true;
  bool _solvedLoading = false;
  bool _solvedLoadMoreFailed = false;
  final LoadMoreCoordinator _solvedLoadMoreCoordinator = LoadMoreCoordinator();

  // 一级栏目用于导航，动态类型在动态栏目内部筛选。
  static const List<String> _tabFilters = [
    'summary',
    'activity',
    'badges',
    'about',
  ];

  /// 桌面端 Esc 关闭当前层:平行视界嵌入层走 onEmbeddedBack,普通路由
  /// maybePop —— 与 TopicDetailPage 的 closeOverlay 语义对齐。
  late final ShortcutScopeBinding _shortcutScopeBinding;

  /// 全屏形态的 ESC 两段式(右栏开着=让分发落 detail scope 关右栏,
  /// 空了=maybePop 关整页),按右栏开合在 build 里动态同步。
  PaneHostEscBinding? _standaloneEsc;

  void _registerShortcuts() {
    if (!PlatformUtils.isDesktop) return;
    // 全屏形态由 _standaloneEsc 动态注册(见 _wrapStandaloneHost),
    // 这里只管嵌入面板形态——否则右栏开着时 context 层的 maybePop
    // 会抢在 detail scope 前面把整页关掉。
    if (!widget.embeddedMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final back = widget.onEmbeddedBack;
      if (back == null) return;
      _shortcutScopeBinding.register(context, {
        ShortcutAction.closeOverlay: back,
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _pinnedActionProgress = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _shortcutScopeBinding = ShortcutScopeBinding(
      ref: ref,
      scope: widget.embeddedMode ? ShortcutScope.detail : ShortcutScope.context,
      // 嵌入面板挂在 IndexedStack 常驻 tab 里:宿主不活跃时注册失效,
      // 否则截胡其他 tab 的 ESC(见 TopicDetailPage 同注)。
      enabled: () => !widget.embeddedMode || widget.parentActive,
    );
    _registerShortcuts();
    _tabController = TabController(length: _tabFilters.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadUser();
  }

  @override
  void dispose() {
    _shortcutScopeBinding.disposeDeferred();
    _standaloneEsc?.dispose();
    _tabController.dispose();
    _scrollController.dispose();
    _pinnedActionProgress.dispose();
    _pullExtent.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_user == null || _user!.profileHidden) return;
    final changed = _activeTabIndex != _tabController.index;
    _activeTabIndex = _tabController.index;
    final section = _tabFilters[_tabController.index];
    if (section == 'activity') _loadActivity(refresh: changed);
    if (section == 'badges' &&
        _badges == null &&
        !_badgesLoading &&
        _badgesError == null) {
      _loadBadges();
    }
  }

  bool _canSeeActivity(String filter) {
    if (_summary?.canSeeUserActions == false) return false;
    if (filter != '${UserActionType.wasLiked}') return true;
    final viewer = ref.read(currentUserProvider).value;
    return viewer != null && (viewer.id == _user?.id || viewer.admin);
  }

  void _loadActivity({bool refresh = false}) {
    if (!_canSeeActivity(_activityFilter)) return;
    switch (_activityFilter) {
      case 'reactions':
        if (!_reactionsLoading &&
            (refresh ||
                (_reactionsCache == null &&
                    !_actionErrors.containsKey('reactions')))) {
          _loadReactions();
        }
      case 'boosts':
        if (!_boostsLoading &&
            (refresh ||
                (_boostsCache == null &&
                    !_actionErrors.containsKey('boosts')))) {
          _loadBoosts();
        }
      case 'votes':
        if (!_votesLoading &&
            (refresh ||
                (_votesCache == null && !_actionErrors.containsKey('votes')))) {
          _loadVotes();
        }
      case 'solved':
        if (!_solvedLoading &&
            (refresh ||
                (_solvedCache == null &&
                    !_actionErrors.containsKey('solved')))) {
          _loadSolved();
        }
      default:
        if (_loadingCache[_activityFilter] != true &&
            (refresh ||
                (!_actionsCache.containsKey(_activityFilter) &&
                    !_actionErrors.containsKey(_activityFilter)))) {
          _loadActions(_activityFilter);
        }
    }
  }

  void _showActivity(String filter) {
    if (!_canSeeActivity(filter)) return;
    setState(() => _activityFilter = filter);
    _activeTabIndex = _tabFilters.indexOf('activity');
    _tabController.animateTo(_activeTabIndex);
    _loadActivity(refresh: true);
  }

  Future<void> _loadUser({bool refresh = false}) async {
    final username = _username;
    try {
      final service = ref.read(discourseServiceProvider);
      final user = await service.getUser(username);
      if (mounted && username == _username) {
        setState(() {
          _user = user;
          _error = null;
          _errorStack = null;
          _isFollowed = user.isFollowed ?? false;
          _notificationLevel = user.ignored == true
              ? 'ignore'
              : user.muted == true
              ? 'mute'
              : 'normal';
          _isLoading = false;
        });
        if (!user.profileHidden) {
          if (refresh) {
            await _loadSummary(forceRefresh: true);
          } else {
            _loadSummary();
            _onTabChanged();
          }
        }
      }
    } catch (e, s) {
      if (mounted && username == _username) {
        setState(() {
          _error = e;
          _errorStack = s;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadSummary({bool forceRefresh = false}) async {
    if (_summaryLoading || _user?.profileHidden == true) return;
    final username = _username;
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
      _summaryErrorStack = null;
    });
    try {
      final summary = await ref
          .read(discourseServiceProvider)
          .getUserSummary(username, forceRefresh: forceRefresh);
      if (mounted && _username == username) {
        setState(() => _summary = summary);
        if (!summary.canSeeUserActions &&
            _tabFilters[_tabController.index] == 'activity') {
          _tabController.animateTo(_tabFilters.indexOf('summary'));
        }
      }
    } catch (error, stack) {
      if (mounted && _username == username) {
        setState(() {
          _summaryError = error;
          _summaryErrorStack = stack;
        });
      }
    } finally {
      if (mounted && _username == username) {
        setState(() => _summaryLoading = false);
      }
    }
  }

  Future<void> _loadBadges() async {
    if (_badgesLoading || _user?.profileHidden == true) return;
    final username = _username;
    setState(() {
      _badgesLoading = true;
      _badgesError = null;
      _badgesErrorStack = null;
    });
    try {
      final response = await ref
          .read(discourseServiceProvider)
          .getUserBadges(username: username);
      if (mounted && _username == username) {
        setState(() => _badges = response.userBadges);
      }
    } catch (error, stack) {
      if (mounted && _username == username) {
        setState(() {
          _badgesError = error;
          _badgesErrorStack = stack;
        });
      }
    } finally {
      if (mounted && _username == username) {
        setState(() => _badgesLoading = false);
      }
    }
  }

  Future<void> _toggleFavoriteBadge(badge_model.UserBadge badge) async {
    if (_savingBadgeId != null) return;
    setState(() => _savingBadgeId = badge.id);
    try {
      await ref
          .read(discourseServiceProvider)
          .toggleFavoriteUserBadge(badge.id);
      if (!mounted) return;
      await _loadBadges();
      if (mounted) await _loadSummary(forceRefresh: true);
    } catch (error, stack) {
      if (error is! DioException) {
        AppErrorHandler.handleUnexpected(error, stack);
      }
    } finally {
      if (mounted) setState(() => _savingBadgeId = null);
    }
  }

  Future<void> _openPreferences({bool editProfile = false}) async {
    final changed = await Navigator.of(context).push<String>(
      InteractionPageRoute(
        builder: (_) => ForumPreferencesPage(
          username: _username,
          initialSection: editProfile ? ForumPreferenceSection.account : null,
        ),
      ),
    );
    if (changed != null && mounted) {
      _renamedUsername = changed;
      await ref
          .read(currentUserProvider.notifier)
          .refreshSilently(force: true, preserveStatus: true);
      if (mounted) await _loadUser();
    }
  }

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

    showReplySheet(context: context, targetUsername: _user!.username);
  }

  /// 发起 1:1 聊天(Chat 插件 DM;服务端 upsert 自动复用旧会话)
  Future<void> _startChat() async {
    if (_user == null || _isStartingChat) return;
    setState(() => _isStartingChat = true);
    try {
      final service = ref.read(discourseServiceProvider);
      final channel = await service.createDirectMessageChannel(
        targetUsernames: [_user!.username],
        upsert: true,
      );
      if (!mounted) return;
      Navigator.push(
        context,
        InteractionPageRoute(
          builder: (_) => ChatChannelPage(channelId: channel.id),
        ),
      );
    } catch (e) {
      ToastService.showError(e.toString());
    } finally {
      if (mounted) setState(() => _isStartingChat = false);
    }
  }

  bool _isStartingChat = false;

  /// 打开用户内容搜索
  void _openUserSearch() {
    Navigator.push(
      context,
      InteractionPageRoute(
        builder: (_) => SearchPage(initialQuery: '@$_username'),
      ),
    );
  }

  /// 分享用户
  void _shareUser() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/u/$_username',
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
          _user = _user!.copyWith(muted: level == 'mute', ignored: false);
        });
        final label = level == 'mute'
            ? S.current.userProfile_setToMute
            : S.current.userProfile_restored;
        ToastService.showSuccess(label);
      }
    } catch (_) {
      if (mounted) setState(() => _notificationLevel = oldLevel);
    }
  }

  /// 显示忽略时长选择弹窗，返回 expiringAt 时间字符串
  Future<String?> _showIgnoreDurationPicker() =>
      showIgnoreDurationPicker(context);

  /// 显示用户详细信息弹窗
  void _showUserInfo() {
    if (_user == null || _user!.profileHidden) return;
    _tabController.animateTo(_tabFilters.indexOf('about'));
  }

  /// 资料详情中的封禁/禁言区块
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
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: ShapeDecoration(
              color: color.withValues(alpha: 0.08),
              shape: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(12),
                side: BorderSide(color: color.withValues(alpha: 0.2)),
              ),
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
                          fontWeight: FontWeight.w500,
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

  Widget _buildInfoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    String? url,
    bool isLink = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: isLink && url != null ? () => launchUrl(Uri.parse(url)) : null,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(8),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: ShapeDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                shape: RoundedSuperellipseBorder(
                  borderRadius: context.shapes.borderRadius(8),
                ),
              ),
              child: Icon(
                icon,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
                      color: isLink
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      decoration: isLink ? TextDecoration.underline : null,
                      decorationColor: theme.colorScheme.primary.withValues(
                        alpha: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (isLink)
              Icon(
                Symbols.open_in_new_rounded,
                size: 16,
                color: theme.colorScheme.outline.withValues(alpha: 0.5),
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
  static final _reactionsPaginationHelper =
      PaginationHelpers.forList<UserReaction>(
        keyExtractor: (r) => r.id,
        expectedPageSize: 20,
      );

  /// 用户 Boost 分页助手（游标分页）
  static final _boostsPaginationHelper = PaginationHelpers.forList<UserBoost>(
    keyExtractor: (b) => b.id,
    expectedPageSize: 20,
  );

  /// 已解决帖子分页助手（offset 分页）
  static final _solvedPaginationHelper = PaginationHelpers.forList<SolvedPost>(
    keyExtractor: (p) => p.postId,
    expectedPageSize: 30,
  );

  LoadMoreCoordinator _actionLoadMoreCoordinator(String filter) {
    return _actionLoadMoreCoordinators.putIfAbsent(
      filter,
      () => LoadMoreCoordinator(),
    );
  }

  Future<void> _loadMoreActions(String filter) async {
    final coordinator = _actionLoadMoreCoordinator(filter);
    await coordinator.loadMore(
      loadMore: () => _loadActions(filter, loadMore: true),
      hasMore: () => _hasMoreCache[filter] ?? true,
      isActive: () => mounted,
      progressCount: () => _actionsCache[filter]?.length ?? 0,
    );
  }

  Future<void> _loadMoreReactions() async {
    await _reactionsLoadMoreCoordinator.loadMore(
      loadMore: () => _loadReactions(loadMore: true),
      hasMore: () => _reactionsHasMore,
      isActive: () => mounted,
      progressCount: () => _reactionsCache?.length ?? 0,
    );
  }

  Future<void> _loadMoreBoosts() async {
    await _boostsLoadMoreCoordinator.loadMore(
      loadMore: () => _loadBoosts(loadMore: true),
      hasMore: () => _boostsHasMore,
      isActive: () => mounted,
      progressCount: () => _boostsCache?.length ?? 0,
    );
  }

  Future<void> _loadMoreVotes() async {
    await _votesLoadMoreCoordinator.loadMore(
      loadMore: () => _loadVotes(loadMore: true),
      hasMore: () => _votesHasMore,
      isActive: () => mounted,
      progressCount: () => _votesCache?.length ?? 0,
    );
  }

  Future<void> _loadMoreSolved() async {
    await _solvedLoadMoreCoordinator.loadMore(
      loadMore: () => _loadSolved(loadMore: true),
      hasMore: () => _solvedHasMore,
      isActive: () => mounted,
      progressCount: () => _solvedCache?.length ?? 0,
    );
  }

  Future<void> _loadActions(String filter, {bool loadMore = false}) async {
    if (!_canSeeActivity(filter)) return;
    // 如果已有数据且正在加载，跳过（防止重复加载更多）
    if (_loadingCache[filter] == true && _actionsCache.containsKey(filter)) {
      return;
    }

    if (!loadMore) {
      _actionLoadMoreCoordinator(filter).resetCooldown();
    }

    setState(() {
      _loadingCache[filter] = true;
      _loadMoreFailedCache[filter] = false;
      _actionErrors.remove(filter);
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final offset = loadMore ? (_actionsCache[filter]?.length ?? 0) : 0;
      final response = await service.getUserActions(
        _username,
        // 与网页的活动流一致，「所有」只请求用户发表的话题和回复。
        filter: filter == 'all'
            ? '${UserActionType.newTopic},${UserActionType.reply}'
            : filter,
        offset: offset,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserAction>(
              items: _actionsCache[filter] ?? [],
            );
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
          _loadMoreFailedCache[filter] = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingCache[filter] = false;
          if (loadMore) {
            _loadMoreFailedCache[filter] = true;
          } else {
            _actionErrors[filter] = e;
          }
        });
      }
    }
  }

  Future<void> _loadReactions({bool loadMore = false}) async {
    if (_reactionsLoading) return;

    if (!loadMore) {
      _reactionsLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _actionErrors.remove('reactions');
      _reactionsLoading = true;
      _reactionsLoadMoreFailed = false;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final beforeId =
          loadMore && _reactionsCache != null && _reactionsCache!.isNotEmpty
          ? _reactionsCache!.last.id
          : null;
      final response = await service.getUserReactions(
        _username,
        beforeReactionUserId: beforeId,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserReaction>(
              items: _reactionsCache ?? [],
            );
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
          _reactionsLoadMoreFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _reactionsLoading = false;
          if (loadMore) {
            _reactionsLoadMoreFailed = true;
          } else {
            _actionErrors['reactions'] = e;
          }
        });
      }
    }
  }

  Future<void> _loadBoosts({bool loadMore = false}) async {
    if (_boostsLoading) return;

    if (!loadMore) {
      _boostsLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _actionErrors.remove('boosts');
      _boostsLoading = true;
      _boostsLoadMoreFailed = false;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final beforeId =
          loadMore && _boostsCache != null && _boostsCache!.isNotEmpty
          ? _boostsCache!.last.id
          : null;
      final response = await service.getUserBoostsGiven(
        _username,
        beforeBoostId: beforeId,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<UserBoost>(
              items: _boostsCache ?? [],
            );
            final result = _boostsPaginationHelper.processLoadMore(
              currentState,
              PaginationResult(items: response.boosts, expectedPageSize: 20),
            );
            _boostsCache = result.items;
            _boostsHasMore = result.hasMore;
          } else {
            final result = _boostsPaginationHelper.processRefresh(
              PaginationResult(items: response.boosts, expectedPageSize: 20),
            );
            _boostsCache = result.items;
            _boostsHasMore = result.hasMore;
          }
          _boostsLoading = false;
          _boostsLoadMoreFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _boostsLoading = false;
          if (loadMore) {
            _boostsLoadMoreFailed = true;
          } else {
            _actionErrors['boosts'] = e;
          }
        });
      }
    }
  }

  Future<void> _loadVotes({bool loadMore = false}) async {
    if (_votesLoading) return;

    if (!loadMore) {
      _votesLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _actionErrors.remove('votes');
      _votesLoading = true;
      _votesLoadMoreFailed = false;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final page = loadMore ? _votesPage + 1 : 0;
      final response = await service.getVotedTopics(_username, page: page);

      if (mounted) {
        setState(() {
          if (loadMore) {
            // 按 id 去重后追加
            final existing = (_votesCache ?? []).map((t) => t.id).toSet();
            final fresh = response.topics.where(
              (t) => !existing.contains(t.id),
            );
            _votesCache = [...?_votesCache, ...fresh];
          } else {
            _votesCache = response.topics;
          }
          _votesPage = page;
          _votesHasMore = response.moreTopicsUrl != null;
          _votesLoading = false;
          _votesLoadMoreFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _votesLoading = false;
          if (loadMore) {
            _votesLoadMoreFailed = true;
          } else {
            _actionErrors['votes'] = e;
          }
        });
      }
    }
  }

  Future<void> _loadSolved({bool loadMore = false}) async {
    if (_solvedLoading) return;

    if (!loadMore) {
      _solvedLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _actionErrors.remove('solved');
      _solvedLoading = true;
      _solvedLoadMoreFailed = false;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final offset = loadMore ? (_solvedCache?.length ?? 0) : 0;
      final response = await service.getUserSolvedPosts(
        _username,
        offset: offset,
      );

      if (mounted) {
        setState(() {
          if (loadMore) {
            final currentState = PaginationState<SolvedPost>(
              items: _solvedCache ?? [],
            );
            final result = _solvedPaginationHelper.processLoadMore(
              currentState,
              PaginationResult(items: response.posts, expectedPageSize: 30),
            );
            _solvedCache = result.items;
            _solvedHasMore = result.hasMore;
          } else {
            final result = _solvedPaginationHelper.processRefresh(
              PaginationResult(items: response.posts, expectedPageSize: 30),
            );
            _solvedCache = result.items;
            _solvedHasMore = result.hasMore;
          }
          _solvedLoading = false;
          _solvedLoadMoreFailed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _solvedLoading = false;
          if (loadMore) {
            _solvedLoadMoreFailed = true;
          } else {
            _actionErrors['solved'] = e;
          }
        });
      }
    }
  }

  /// 宽屏排版:内容限宽居中(头图背景保持全宽出血)。嵌入面板/窄屏
  /// 时面板宽本就有限,约束不生效,零冲突。
  Widget _constrainWide(Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUser = ref.watch(currentUserProvider).value;
    if (_user != null && _user!.id == currentUser?.id) {
      _user = _user!.copyWith(identity: currentUser);
    }

    if (_isLoading) {
      return UserProfileSkeleton(
        embeddedMode: widget.embeddedMode,
        onBack: widget.onEmbeddedBack,
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_username),
          // embeddedMode 但 onEmbeddedBack 为空（master 面板的"上一层
          // 预览"，非当前可交互栈顶）时不该有任何返回键——之前不管
          // onEmbeddedBack 是否为空都塞 BackButton，BackButton(onPressed:
          // null) 不会被禁用，而是退化成默认的 Navigator.maybePop()，
          // 直接捅穿到应用根导航栈（表现为点它弹出"再点一次退出"提示，
          // 然后卡死）。automaticallyImplyLeading 也要关掉，否则即使
          // leading 传 null，只要外层 Navigator 能 pop，Flutter 还是会
          // 自动塞一个隐式返回键，同样的问题。
          automaticallyImplyLeading: !widget.embeddedMode,
          leading: widget.embeddedMode && widget.onEmbeddedBack != null
              ? BackButton(onPressed: widget.onEmbeddedBack)
              : null,
        ),
        body: ErrorView(
          error: _error!,
          stackTrace: _errorStack,
          onRetry: () {
            setState(() {
              _isLoading = true;
              _error = null;
              _errorStack = null;
            });
            _loadUser();
          },
        ),
      );
    }

    final Widget profileBody = LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(
          constraints.maxWidth,
          UserProfileWideLayout.maxWidth,
        );
        return PageBackdrop(
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: _buildProfileBody(theme, currentUser, width),
            ),
          ),
        );
      },
    );

    // 嵌入形态(别的宿主的面板):本页只是一格内容,原样返回。
    if (widget.embeddedMode) return profileBody;

    // 全屏形态:本页自己是平行视界宿主——资料页作 master,宽屏点
    // 话题/回复进右栏,缩窄时右栏内容转投影,窄屏点列表走真路由。
    return _wrapStandaloneHost(profileBody);
  }

  /// 各 Tab 的内容页(宽窄两版共用同一份,State 级缓存不受切换影响)。
  List<Widget> _buildTabViews() {
    return _tabFilters.asMap().entries.map((entry) {
      final index = entry.key;
      final filter = entry.value;
      return ExtendedVisibilityDetector(
        uniqueKey: Key('tab_$index'),
        child: switch (filter) {
          'summary' => _buildSummaryTab(),
          'activity' => _constrainWide(_buildActivityTab()),
          'badges' => _constrainWide(_buildBadgesTab()),
          _ => _constrainWide(_buildProfileInformation()),
        },
      );
    }).toList();
  }

  void _updatePinnedActionProgress(double progress) {
    if (_pendingPinnedActionProgress != null) {
      _pendingPinnedActionProgress = progress;
      return;
    }
    _pendingPinnedActionProgress = progress;
    // 嵌套滚动一帧可多次布局，只发布最后一次布局的结果。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final latestProgress = _pendingPinnedActionProgress!;
      _pendingPinnedActionProgress = null;
      if (!mounted) return;
      // 阈值两侧保留少量回差，慢拖停在边界时不会反复切换。
      final pinned = latestProgress >= (_actionsPinned ? 0.4 : 0.6);
      if (pinned == _actionsPinned) return;
      _actionsPinned = pinned;
      // 快速越过边界也播放完整过渡，反向时从当前画面接续。
      _pinnedActionProgress.animateTo(
        pinned ? 1 : 0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _buildProfileToolbar(
    User? currentUser,
    double titleOpacity,
    bool shareCollapsed,
    double width,
  ) {
    final own = currentUser?.id == _user!.id;
    final theme = Theme.of(context);
    var actionWidth = 48.0;
    if (!own && _user!.canFollow == true) {
      final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      );
      for (final label in [
        context.l10n.userProfile_follow,
        context.l10n.userProfile_followed,
      ]) {
        painter.text = TextSpan(
          text: label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        );
        painter.layout();
        actionWidth = math.max(actionWidth, painter.width + 40);
      }
      painter.dispose();
    }
    final iconOnly = actionWidth > width - 112;
    if (iconOnly) actionWidth = 48;
    return ValueListenableBuilder<double>(
      valueListenable: _pinnedActionProgress,
      builder: (context, progress, _) {
        final canPin = own ? _user!.canEdit : _user!.canFollow == true;
        final actionProgress = canPin ? progress : 0.0;
        final searchOpacity = 1 - actionProgress;
        final pinnedOpacity = actionProgress;
        final actions = _buildHeaderActions(
          own,
          shareCollapsed: shareCollapsed,
          actionsCollapsed: _actionsPinned,
        );
        return AppBar(
          titleSpacing: 4,
          foregroundColor: theme.colorScheme.onSurface,
          title: Opacity(
            opacity: titleOpacity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _user!.name?.isNotEmpty == true
                      ? _user!.name!
                      : _user!.username,
                  key: const ValueKey('profile-toolbar-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_summary?.canSeeSummaryStats == true &&
                    MediaQuery.textScalerOf(context).scale(14) < 20)
                  Text(
                    '${NumberUtils.formatCount(_summary!.topicCount)} ${context.l10n.userProfile_statsTopics} · ${NumberUtils.formatCount(_summary!.postCount)} ${context.l10n.userProfile_statsReplies}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          forceMaterialTransparency: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: !widget.embeddedMode,
          leading: widget.embeddedMode && widget.onEmbeddedBack != null
              ? BackButton(onPressed: widget.onEmbeddedBack)
              : null,
          actions: [
            SizedBox(
              width: actionWidth + 48,
              height: kToolbarHeight,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  PositionedDirectional(
                    start: (actionWidth - 48) * (1 - actionProgress),
                    width: 48,
                    child: IgnorePointer(
                      ignoring: canPin && _actionsPinned,
                      child: Opacity(
                        key: const ValueKey('profile-toolbar-search-opacity'),
                        opacity: searchOpacity,
                        child: Center(child: actions.first),
                      ),
                    ),
                  ),
                  if (canPin)
                    PositionedDirectional(
                      start: 48,
                      width: actionWidth,
                      child: IgnorePointer(
                        ignoring: !_actionsPinned,
                        child: Opacity(
                          key: const ValueKey('profile-toolbar-action-opacity'),
                          opacity: pinnedOpacity,
                          child: Center(
                            child: own
                                ? IconButton(
                                    key: const ValueKey('profile-pinned-edit'),
                                    tooltip: context.l10n.profile_editProfile,
                                    onPressed: () =>
                                        _openPreferences(editProfile: true),
                                    icon: const Icon(Symbols.edit_rounded),
                                  )
                                : Padding(
                                    key: const ValueKey(
                                      'profile-pinned-follow',
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: _buildFollowButton(
                                      compact: true,
                                      iconOnly: iconOnly,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  PositionedDirectional(
                    start: actionWidth * (1 - actionProgress),
                    width: 48,
                    child: Center(child: actions.last),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
          ],
        );
      },
    );
  }

  Future<void> _refreshProfile() async {
    await _loadUser(refresh: true);
    if (!mounted || _user?.profileHidden == true) return;
    switch (_tabFilters[_tabController.index]) {
      case 'activity':
        await switch (_activityFilter) {
          'reactions' => _loadReactions(),
          'boosts' => _loadBoosts(),
          'votes' => _loadVotes(),
          'solved' => _loadSolved(),
          _ => _loadActions(_activityFilter),
        };
      case 'badges':
        await _loadBadges();
    }
  }

  Widget _buildProfileBody(ThemeData theme, User? currentUser, double width) {
    final topInset = MediaQuery.paddingOf(context).top;
    final pinnedHeaderHeight =
        topInset + kToolbarHeight + (_user!.profileHidden ? 0 : 48);
    final wide =
        width >= UserProfileWideLayout.minWidth &&
        width >= MediaQuery.textScalerOf(context).scale(14) * 60;
    final buttons = _buildProfileActionButtons(theme, currentUser, wide: wide);
    final actionHeight = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(14) * 1.4 + 12,
    );
    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: false,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context)
              .copyWith(scrollbars: false, overscroll: false),
          child: M3eRefreshIndicator(
            displacement: 32,
            triggerMode: RefreshIndicatorTriggerMode.anywhere,
            onPullExtentChanged: (extent) => _pullExtent.value = extent * 2,
            indicatorBuilder: (context, indicator) => Positioned(
              top: topInset,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_pullExtent, _scrollController]),
                  child: indicator,
                  builder: (context, child) {
                    final scroll = _scrollController.hasClients
                        ? _scrollController.offset
                        : 0.0;
                    return ClipRect(
                      child: SizedBox(
                        key: const ValueKey('profile-refresh-indicator'),
                        height: math.max(0, _pullExtent.value - scroll),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              top: -scroll,
                              left: 0,
                              right: 0,
                              height: _pullExtent.value,
                              child: Center(child: child),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.vertical,
            edgePredicate: (notification) =>
                notification.metrics.extentBefore == 0 &&
                (!_scrollController.hasClients ||
                    _scrollController.offset <= 0),
            onRefresh: _refreshProfile,
            child: ExtendedNestedScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              controller: _scrollController,
              pinnedHeaderSliverHeightBuilder: () => pinnedHeaderHeight,
              onlyOneScrollInBody: true,
              headerSliverBuilder: (context, innerBoxIsScrolled) => [
                ValueListenableBuilder<double>(
                  valueListenable: _pullExtent,
                  builder: (context, extent, _) => SliverPersistentHeader(
                    pinned: true,
                    delegate: UserProfileHeaderDelegate(
                      context: context,
                      width: width,
                      header: _buildProfileHeader(
                        theme,
                        currentUser,
                        wide: wide,
                      ),
                      toolbarBuilder: (opacity, shareCollapsed) =>
                          _buildProfileToolbar(
                            currentUser,
                            opacity,
                            shareCollapsed,
                            width,
                          ),
                      topInset: topInset,
                      pullExtent: extent,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: wide
                      ? const SizedBox.shrink()
                      : _buildProfileDetails(theme),
                ),
                SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final progress = buttons.isEmpty
                        ? 0.0
                        : ((constraints.scrollOffset +
                                      constraints.overlap -
                                      actionHeight +
                                      12) /
                                  24)
                              .clamp(0.0, 1.0);
                    _updatePinnedActionProgress(progress);
                    final actions = buttons.isEmpty
                        ? const SizedBox.shrink()
                        : SizedBox(
                            key: const ValueKey('profile-primary-actions'),
                            height: actionHeight,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (
                                  var index = 0;
                                  index < buttons.length;
                                  index++
                                ) ...[
                                  if (index > 0) const SizedBox(width: 8),
                                  Expanded(child: buttons[index]),
                                ],
                              ],
                            ),
                          );
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 0 : 16,
                          4,
                          16,
                          wide ? 20 : 8,
                        ),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _buildProfileDetails(
                                      theme,
                                      wide: true,
                                    ),
                                  ),
                                  if (buttons.isNotEmpty) ...[
                                    const SizedBox(width: 24),
                                    SizedBox(
                                      width:
                                          buttons.length * 120 +
                                          (buttons.length - 1) * 8,
                                      child: actions,
                                    ),
                                  ],
                                ],
                              )
                            : actions,
                      ),
                    );
                  },
                ),
                if (!_user!.profileHidden)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _ProfileTabsDelegate(
                      child: _buildTabBar(theme, wide: wide),
                    ),
                  ),
              ],
              body: _user!.profileHidden
                  ? _buildHiddenProfile()
                  : TabBarView(
                      controller: _tabController,
                      children: _buildTabViews(),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHiddenProfile() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          context.l10n.userProfile_hidden,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  UserProfileHeader _buildProfileHeader(
    ThemeData theme,
    User? currentUser, {
    bool wide = false,
  }) {
    return UserProfileHeader(
      user: _user!,
      wide: wide,
      avatar: _buildTappableAvatar(
        radius: 40,
        flairSize: 28,
        flairRight: -4,
        flairBottom: -2,
        borderColor: theme.colorScheme.surface,
        borderWidth: 3,
      ),
      trailing: IconButton.outlined(
        tooltip: context.l10n.userProfile_shareUser,
        onPressed: _shareUser,
        icon: const Icon(Symbols.share_rounded, size: 20),
      ),
      onBackground: () {
        final background = _user!.backgroundUrl;
        if (background?.isNotEmpty == true) {
          const style = ViewerSourceStyle.cover(radius: 0);
          ImageViewerPage.open(
            context,
            background!,
            heroTag: 'user_cover_${_user!.username}',
            thumbnailUrl: background,
            heroSourceFit: style.openViewerArgs.fit,
            heroSourceRadius: style.openViewerArgs.radius,
          );
        }
      },
    );
  }

  List<Widget> _buildProfileActionButtons(
    ThemeData theme,
    User? currentUser, {
    bool wide = false,
  }) {
    final user = _user!;
    final own = currentUser?.id == user.id;
    final canMessage =
        currentUser != null && !own && user.canSendPrivateMessageToUser == true;
    final canChat = currentUser != null && !own && user.canChatUser == true;
    final style = OutlinedButton.styleFrom(
      foregroundColor: theme.colorScheme.onSurface,
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      side: BorderSide(color: theme.colorScheme.outlineVariant),
      minimumSize: const Size(0, 40),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return [
      if (own && user.canEdit)
        OutlinedButton(
          style: style,
          onPressed: () => _openPreferences(editProfile: true),
          child: Text(
            context.l10n.profile_editProfile,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (canMessage && canChat && !wide)
        Builder(
          builder: (anchorContext) => OutlinedButton(
            style: style,
            onPressed: () => _showContactMenu(anchorContext),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    context.l10n.userProfile_contact,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Symbols.expand_more_rounded, size: 18),
              ],
            ),
          ),
        )
      else ...[
        if (canMessage)
          OutlinedButton.icon(
            style: style,
            onPressed: _openMessageDialog,
            icon: const Icon(Symbols.mail_rounded, size: 18),
            label: Text(context.l10n.userProfile_message),
          ),
        if (canChat)
          OutlinedButton.icon(
            style: style,
            onPressed: _isStartingChat ? null : _startChat,
            icon: const Icon(Symbols.chat_bubble_rounded, size: 18),
            label: Text(context.l10n.chat_title),
          ),
      ],
      if (!own && user.canFollow == true) _buildFollowButton(),
    ];
  }

  Future<void> _showContactMenu(BuildContext anchorContext) async {
    final overlay =
        Navigator.of(anchorContext).overlay!.context.findRenderObject()
            as RenderBox;
    final anchor = anchorContext.findRenderObject() as RenderBox;
    final rect =
        anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
    final value = await showSwipeDismissibleMenu<String>(
      context: anchorContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(rect.left, rect.bottom + 4, rect.width, 0),
        Offset.zero & overlay.size,
      ),
      animationAnchorRect: rect,
      items: [
        _profileMenuItem(
          'message',
          Symbols.mail_rounded,
          context.l10n.userProfile_message,
        ),
        _profileMenuItem(
          'chat',
          Symbols.chat_bubble_rounded,
          context.l10n.chat_title,
          enabled: !_isStartingChat,
        ),
      ],
    );
    if (!mounted) return;
    if (value == 'message') _openMessageDialog();
    if (value == 'chat') _startChat();
  }

  Widget _buildProfileDetails(ThemeData theme, {bool wide = false}) {
    final status = ref.watch(userStatusForProvider((userId: _user!.id, initial: _user!.status)));
    final user = _user!.copyWith(status: status, clearStatus: status == null);
    return UserProfileDetails(
      user: user,
      showUsername: !wide,
      statusIcon: user.status?.emoji?.isNotEmpty == true
          ? _buildStatusEmoji(user.status!)
          : null,
      onAbout: _showUserInfo,
      onFollowing: () => Navigator.of(context).push(
        InteractionPageRoute(
          builder: (_) =>
              FollowListPage(username: user.username, isFollowing: true),
        ),
      ),
      onFollowers: () => Navigator.of(context).push(
        InteractionPageRoute(
          builder: (_) =>
              FollowListPage(username: user.username, isFollowing: false),
        ),
      ),
      restriction: user.isSuspended || user.isSilenced
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (user.isSuspended)
                  _buildRestrictionBanner(
                    icon: Symbols.block_rounded,
                    label: user.isSuspendedForever
                        ? context.l10n.userProfile_suspendedBannerForever
                        : context.l10n.userProfile_suspendedBannerUntil(
                            TimeUtils.formatFullDate(user.suspendedTill),
                          ),
                    reason: user.suspendReason,
                    color: theme.colorScheme.error,
                    reasonColor: theme.colorScheme.onSurfaceVariant,
                  ),
                if (user.isSilenced)
                  _buildRestrictionBanner(
                    icon: Symbols.mic_off_rounded,
                    label: user.isSilencedForever
                        ? context.l10n.userProfile_silencedBannerForever
                        : context.l10n.userProfile_silencedBannerUntil(
                            TimeUtils.formatFullDate(user.silencedTill),
                          ),
                    reason: user.silenceReason,
                    color: context.appColors.orangeAccent,
                    reasonColor: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            )
          : null,
    );
  }

  /// 可点开查看器的头像(带 flair/Hero,竖版头图区与宽版骑缝位共用
  /// 同一套打开逻辑,只是尺寸与描边不同)。
  Widget _buildTappableAvatar({
    required double radius,
    required double flairSize,
    required double flairRight,
    required double flairBottom,
    required Color borderColor,
    required double borderWidth,
  }) {
    final avatarUrl = _user?.getAvatarUrl(size: 144);
    final isSquare = isSquareAvatarUrl(avatarUrl);
    return GestureDetector(
      onTap: () {
        if (_user?.getAvatarUrl() != null) {
          final fullUrl = _user!.getAvatarUrl(size: 360);
          // 与页面头像同参(144)的缩略图作飞行纹理,命中已解码缓存
          final thumbUrl = _user!.getAvatarUrl(size: 144);
          // 与源端同源:同一个 _avatarStyle(isSquare, radius: 12)。
          // 此前这里写死 radius 8 而源端 borderRadius 12,两处不同步。
          final args = _avatarStyle(
            isSquare: isSquareAvatarUrl(thumbUrl),
            radius: 12,
          ).openViewerArgs;
          ImageViewerPage.open(
            context,
            fullUrl,
            heroTag: 'user_avatar_${_user!.username}',
            thumbnailUrl: thumbUrl,
            heroSourceFit: args.fit,
            heroSourceRadius: args.radius,
            heroSourceCircular: args.circular,
          );
        }
      },
      child: Container(
        decoration: ShapeDecoration(
          shape: isSquare
              ? RoundedSuperellipseBorder(
                  borderRadius: context.shapes.borderRadius(12),
                  side: BorderSide(color: borderColor, width: borderWidth),
                )
              : CircleBorder(
                  side: BorderSide(color: borderColor, width: borderWidth),
                ),
        ),
        child: AvatarWithFlair(
          flairSize: flairSize,
          flairRight: flairRight,
          flairBottom: flairBottom,
          flairUrl: _user?.flairUrl,
          flairName: _user?.flairName,
          flairBgColor: _user?.flairBgColor,
          flairColor: _user?.flairColor,
          // HeroImage 统一件:飞行起点、源端隐藏/占位、圆角(或圆形)插值
          // 都由它保证;style 同时约束 openViewer 侧参数
          avatar: HeroImage(
            heroTag: 'user_avatar_${_user?.username ?? ''}',
            style: _avatarStyle(isSquare: isSquare, radius: 12),
            flightImage: avatarUrl == null
                ? null
                : discourseImageProvider(avatarUrl),
            child: SmartAvatar(
              imageUrl: avatarUrl,
              radius: radius,
              fallbackText: _user?.username,
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor: Theme.of(context)
                  .colorScheme
                  .onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFollowButton({bool compact = false, bool iconOnly = false}) {
    final theme = Theme.of(context);
    final label = _isFollowLoading
        ? const LoadingSpinner(size: 16)
        : iconOnly
        ? Tooltip(
            message: _isFollowed
                ? context.l10n.userProfile_followed
                : context.l10n.userProfile_follow,
            child: Icon(
              _isFollowed
                  ? Symbols.how_to_reg_rounded
                  : Symbols.person_add_rounded,
              size: 18,
            ),
          )
        : Text(
            _isFollowed
                ? context.l10n.userProfile_followed
                : context.l10n.userProfile_follow,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    final style = FilledButton.styleFrom(
      padding: EdgeInsets.symmetric(
        horizontal: iconOnly
            ? 8
            : compact
            ? 16
            : 20,
      ),
      minimumSize: Size(compact ? 72 : 0, 40),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: theme.colorScheme.onSurface,
      foregroundColor: theme.colorScheme.surface,
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
    return _isFollowed
        ? OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(
                horizontal: iconOnly
                    ? 8
                    : compact
                    ? 16
                    : 20,
              ),
              minimumSize: Size(compact ? 72 : 0, 40),
              visualDensity: VisualDensity.standard,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: theme.colorScheme.onSurface,
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            onPressed: _isFollowLoading ? null : _toggleFollow,
            child: label,
          )
        : FilledButton(
            style: style,
            onPressed: _isFollowLoading ? null : _toggleFollow,
            child: label,
          );
  }

  /// 全屏形态的平行视界宿主组装:栈空=资料页独占全宽(自己的宽屏
  /// 排版,无右栏空白);点话题/回复=资料页收窄成左栏、详情从右滑入
  /// (对半分);缩窄=详情转投影;窄屏点列表=真路由。
  Widget _wrapStandaloneHost(Widget profileBody) {
    final selected = ref.watch(_ownPaneProvider);

    // ESC 两段式:右栏开着让分发落 detail scope(关右栏),空了才
    // maybePop 关整页。
    (_standaloneEsc ??= PaneHostEscBinding(
      ref: ref,
    )).sync(context, paneOpen: selected.hasSelection);

    final notifier = ref.read(_ownPaneProvider.notifier);
    return PaneProjectionBackScope(
      stackProvider: _ownPaneProvider,
      masterWidth: PaneBreakpoints.wideMasterWidth,
      minDetailWidth: PaneBreakpoints.wideMinDetailWidth,
      child: MasterDetailLayout(
        masterWidth: PaneBreakpoints.wideMasterWidth,
        minDetailWidth: PaneBreakpoints.wideMinDetailWidth,
        // 压栈后左栏是资料页(内容不是窄列表),放宽到对半分。
        maxMasterRatio: 0.8,
        preferredMasterRatio: 0.5,
        projectDetailWhenNarrow: true,
        pinMaster: false,
        masterFillsWhenEmpty: true,
        master: profileBody,
        panes: [
          for (var i = 0; i < selected.stack.length; i++)
            KeyedSubtree(
              key: ValueKey(
                'user_profile_pane_${selected.stack[i].kind}_'
                '${selected.stack[i].instanceId ?? selected.stack[i].username ?? selected.stack[i].topicId}',
              ),
              child: PaneContentWidget(
                entry: selected.stack[i],
                stackProvider: _ownPaneProvider,
                parentActive: true,
                truncateOnPush: i < selected.stack.length - 1,
                // 回调内重读 provider,不闭包捕获 build 时的快照。
                onBack: () {
                  if (ref.read(_ownPaneProvider).isStacked) {
                    notifier.pop();
                  } else {
                    notifier.clear();
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Map<String, String> get _activityFilters => {
    'all': context.l10n.userProfile_allActivity,
    '4': context.l10n.userProfile_tabTopics,
    '5': context.l10n.userProfile_tabReplies,
    '1': context.l10n.userProfile_tabLikes,
    if (_canSeeActivity('${UserActionType.wasLiked}'))
      '${UserActionType.wasLiked}': context.l10n.userProfile_statsLikes,
    'reactions': context.l10n.userProfile_tabReactions,
    'boosts': context.l10n.userProfile_tabBoosts,
    'votes': context.l10n.userProfile_tabVotes,
    'solved': context.l10n.userProfile_tabSolved,
  };

  Widget _buildTabBar(ThemeData theme, {bool wide = false}) =>
      MenuTabBar<String>(
        controller: _tabController,
        showAllLabels: wide,
        items: [
          for (final section in _tabFilters)
            switch (section) {
              'activity' => MenuTabItem(
                label: _activityFilter == 'all'
                    ? context.l10n.userProfile_tabActivity
                    : _activityFilters[_activityFilter] ??
                          context.l10n.userProfile_tabActivity,
                icon: Symbols.article_rounded,
                selectedValue: _activityFilter,
                onSelected: _showActivity,
                menuBuilder: (_) => [
                  for (final filter in _activityFilters.entries)
                    CheckedPopupMenuItem(
                      value: filter.key,
                      checked: filter.key == _activityFilter,
                      child: Text(filter.value),
                    ),
                ],
              ),
              'summary' => MenuTabItem(
                label: context.l10n.userProfile_overview,
                icon: Symbols.bar_chart_rounded,
              ),
              'badges' => MenuTabItem(
                label: context.l10n.userProfile_badges,
                icon: Symbols.workspace_premium_rounded,
              ),
              _ => MenuTabItem(
                label: context.l10n.common_about,
                icon: Symbols.info_rounded,
              ),
            },
        ],
      );

  /// 顶部统一放置搜索与更多操作，联系入口位于资料头部。
  List<Widget> _buildHeaderActions(
    bool isOwnProfile, {
    required bool shareCollapsed,
    required bool actionsCollapsed,
  }) {
    return <Widget>[
      IconButton(
        icon: const Icon(Symbols.search_rounded),
        onPressed: () => _openUserSearch(),
        tooltip: context.l10n.common_search,
      ),
      SwipeDismissiblePopupMenuButton<String>(
        key: const ValueKey('profile-more-menu'),
        tooltip: context.l10n.common_more,
        icon: const Icon(Symbols.more_vert_rounded),
        onSelected: (value) {
          switch (value) {
            case 'search':
              _openUserSearch();
            case 'message':
              _openMessageDialog();
            case 'chat':
              _startChat();
            case 'share':
              _shareUser();
            case 'preferences':
              _openPreferences();
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
            if (isOwnProfile && _user?.canEdit == true)
              _profileMenuItem(
                'preferences',
                Symbols.settings_rounded,
                context.l10n.userProfile_forumPreferences,
              ),
            if (actionsCollapsed &&
                (isOwnProfile ? _user!.canEdit : _user!.canFollow == true))
              _profileMenuItem(
                'search',
                Symbols.search_rounded,
                context.l10n.common_search,
              ),
            if (shareCollapsed)
              _profileMenuItem(
                'share',
                Symbols.share_rounded,
                context.l10n.userProfile_shareUser,
              ),
            if (actionsCollapsed &&
                !isOwnProfile &&
                _user?.canSendPrivateMessageToUser == true)
              _profileMenuItem(
                'message',
                Symbols.mail_rounded,
                context.l10n.userProfile_message,
              ),
            if (actionsCollapsed && !isOwnProfile && _user?.canChatUser == true)
              _profileMenuItem(
                'chat',
                Symbols.chat_bubble_rounded,
                context.l10n.chat_title,
                enabled: !_isStartingChat,
              ),
            // 非自己才显示订阅级别选项
            if (!isOwnProfile &&
                _user != null &&
                ref.read(currentUserProvider).value != null) ...[
              if (shareCollapsed) const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'level_normal',
                child: Row(
                  children: [
                    Icon(
                      Symbols.notifications_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurface,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.l10n.userProfile_normal)),
                    if (_notificationLevel == 'normal')
                      Icon(
                        Symbols.check_rounded,
                        size: 18,
                        color: context.emphasis.selected,
                      ),
                  ],
                ),
              ),
              if (_user!.canMuteUser != false)
                PopupMenuItem<String>(
                  value: 'level_mute',
                  child: Row(
                    children: [
                      Icon(
                        Symbols.notifications_off_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurface,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(context.l10n.userProfile_mute)),
                      if (_notificationLevel == 'mute')
                        Icon(
                          Symbols.check_rounded,
                          size: 18,
                          color: context.emphasis.selected,
                        ),
                    ],
                  ),
                ),
              if (_user!.canIgnoreUser == true)
                PopupMenuItem<String>(
                  value: 'level_ignore',
                  child: Row(
                    children: [
                      Icon(
                        Symbols.visibility_off_rounded,
                        size: 20,
                        color: theme.colorScheme.onSurface,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(context.l10n.userProfile_ignored)),
                      if (_notificationLevel == 'ignore')
                        Icon(
                          Symbols.check_rounded,
                          size: 18,
                          color: context.emphasis.selected,
                        ),
                    ],
                  ),
                ),
            ],
          ];
        },
      ),
    ];
  }

  PopupMenuItem<String> _profileMenuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) => PopupMenuItem(
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    ),
  );

  Widget _buildRestrictionBanner({
    required IconData icon,
    required String label,
    required String? reason,
    required Color color,
    Color? reasonColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.15),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(8),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
        ),
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
                    fontWeight: FontWeight.w600,
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
                color: reasonColor ?? Colors.white.withValues(alpha: 0.8),
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

    final isEmojiName =
        emoji.contains(RegExp(r'[a-zA-Z0-9_]')) &&
        !emoji.contains(RegExp(r'[^\x00-\x7F]'));

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

    return Text(emoji, style: const TextStyle(fontSize: 16));
  }

  Widget _buildActivityTab() {
    if (!_canSeeActivity(_activityFilter)) {
      return AppEmptyState(
        icon: const Icon(Symbols.lock_rounded),
        title: context.l10n.userProfile_activityPrivate,
      );
    }
    return KeyedSubtree(
      key: ValueKey(_activityFilter),
      child: _buildActionList(_activityFilter),
    );
  }

  Widget _buildBadgesTab() {
    if (_badgesLoading && _badges == null) {
      return const UserBadgeListSkeleton();
    }
    if (_badgesError != null) {
      return ErrorView(
        error: _badgesError!,
        stackTrace: _badgesErrorStack,
        onRetry: _loadBadges,
      );
    }
    final badges = _badges ?? const <badge_model.UserBadge>[];
    final own = ref.watch(currentUserProvider).value?.id == _user?.id;
    final theme = Theme.of(context);
    return ListView(
      key: PageStorageKey('user_${_username}_badges'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      children: [
        if (badges.isEmpty)
          AppEmptyState(
            icon: const Icon(Symbols.workspace_premium_rounded),
            title: context.l10n.myBadges_empty,
          ),
        for (final type in badge_model.BadgeType.values)
          if (badges.any((entry) => entry.badge?.badgeType == type)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(type.label, style: theme.textTheme.titleSmall),
            ),
            SegmentedCardGroup(
              children: [
                for (final entry in badges.where(
                  (item) => item.badge?.badgeType == type,
                ))
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: FaIcon(
                      BadgeUIUtils.getBadgeIcon(type),
                      color: BadgeUIUtils.getBadgeColor(context, type),
                      size: 24,
                    ),
                    title: Text(entry.badge!.name),
                    subtitle: CollapsedHtmlContent(
                      html: entry.badge!.description,
                      textStyle: theme.textTheme.bodySmall,
                    ),
                    onTap: () => Navigator.of(context).push(
                      InteractionPageRoute(
                        builder: (_) => BadgePage(
                          badgeId: entry.badgeId,
                          username: _username,
                        ),
                      ),
                    ),
                    trailing: own && entry.canFavorite == true
                        ? IconButton(
                            tooltip: entry.isFavorite == true
                                ? context.l10n.userProfile_unfeatureBadge
                                : context.l10n.userProfile_featureBadge,
                            isSelected: entry.isFavorite == true,
                            selectedIcon: const Icon(
                              Symbols.star_rounded,
                              fill: 1,
                            ),
                            icon: _savingBadgeId == entry.id
                                ? const LoadingSpinner(size: 20)
                                : const Icon(Symbols.star_rounded),
                            onPressed: _savingBadgeId == null
                                ? () => _toggleFavoriteBadge(entry)
                                : null,
                          )
                        : entry.count > 1
                        ? Text('× ${entry.count}')
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
      ],
    );
  }

  Widget _buildProfileInformation() {
    final user = _user!;
    final theme = Theme.of(context);
    final fields =
        (PreloadedDataService().siteSync?['user_fields'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((field) => field['show_on_profile'] == true)
            .toList()
          ..sort(
            (a, b) => ((a['position'] as num?) ?? 0).compareTo(
              (b['position'] as num?) ?? 0,
            ),
          );
    return ListView(
      key: PageStorageKey('user_${_username}_about'),
      padding: const EdgeInsets.all(20),
      children: [
        if (user.bio?.isNotEmpty == true) ...[
          Text(context.l10n.userProfile_bio, style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          FluxdoRenderCallbacks.generic(
            heroTagNamespace: 'user_profile_bio_${user.username}',
          ).render(
            cookedHtml: user.bio!,
            baseTextStyle: theme.textTheme.bodyLarge,
            selectionEnabled: false,
          ),
          const SizedBox(height: 24),
        ],
        if (user.title?.isNotEmpty == true)
          _buildInfoRow(
            context,
            Symbols.badge_rounded,
            context.l10n.userProfile_title,
            user.title!,
          ),
        if (user.location?.isNotEmpty == true)
          _buildInfoRow(
            context,
            Symbols.location_on_rounded,
            context.l10n.userProfile_location,
            user.location!,
          ),
        if (user.website?.isNotEmpty == true)
          _buildInfoRow(
            context,
            Symbols.link_rounded,
            context.l10n.userProfile_website,
            user.websiteName ?? user.website!,
            isLink: true,
            url: user.website,
          ),
        if (user.createdAt != null)
          _buildInfoRow(
            context,
            Symbols.calendar_today_rounded,
            context.l10n.userProfile_joinDate,
            TimeUtils.formatFullDate(user.createdAt),
          ),
        if (user.lastSeenAt != null)
          _buildInfoRow(
            context,
            Symbols.schedule_rounded,
            context.l10n.userProfile_lastSeen,
            TimeUtils.formatFullDate(user.lastSeenAt),
          ),
        if (user.lastPostedAt != null)
          _buildInfoRow(
            context,
            Symbols.edit_rounded,
            context.l10n.userProfile_lastPosted,
            TimeUtils.formatFullDate(user.lastPostedAt),
          ),
        if (user.profileViewCount != null)
          _buildInfoRow(
            context,
            Symbols.visibility_rounded,
            context.l10n.userProfile_views,
            NumberUtils.formatCount(user.profileViewCount!),
          ),
        if (user.invitedBy != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.userProfile_invitedBy),
            subtitle: Text(user.invitedBy!.username),
            trailing: const Icon(Symbols.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              InteractionPageRoute(
                builder: (_) =>
                    UserProfilePage(username: user.invitedBy!.username),
              ),
            ),
          ),
        if (user.groups.isNotEmpty) ...[
          Text(
            context.l10n.userProfile_groups,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: user.groups
                .map(
                  (group) => ActionChip(
                    label: Text(group.displayName),
                    onPressed: () => Navigator.of(context).push(
                      InteractionPageRoute(
                        builder: (_) => GroupPage(name: group.name),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
        ],
        for (final field in fields)
          if (user.userFields['${field['id']}']?.toString().isNotEmpty == true)
            _buildInfoRow(
              context,
              Symbols.info_rounded,
              field['name'] as String? ?? '',
              user.userFields['${field['id']}'] is List
                  ? (user.userFields['${field['id']}'] as List).join(' · ')
                  : user.userFields['${field['id']}'].toString(),
            ),
        if (user.isSuspended)
          _buildRestrictionSection(
            theme,
            icon: Symbols.block_rounded,
            title: context.l10n.userProfile_suspendedStatus,
            label: user.isSuspendedForever
                ? context.l10n.userProfile_permanentlySuspended
                : context.l10n.userProfile_suspendedUntil(
                    TimeUtils.formatFullDate(user.suspendedTill),
                  ),
            reason: user.suspendReason,
            color: theme.colorScheme.error,
          ),
        if (user.isSilenced)
          _buildRestrictionSection(
            theme,
            icon: Symbols.mic_off_rounded,
            title: context.l10n.userProfile_silencedStatus,
            label: user.isSilencedForever
                ? context.l10n.userProfile_permanentlySilenced
                : context.l10n.userProfile_silencedUntil(
                    TimeUtils.formatFullDate(user.silencedTill),
                  ),
            reason: user.silenceReason,
            color: context.appColors.orangeAccent,
          ),
      ],
    );
  }

  Widget _buildActionList(String filter) {
    if (_actionErrors.containsKey(filter)) {
      final retry = switch (filter) {
        'reactions' => () => _loadReactions(),
        'boosts' => () => _loadBoosts(),
        'votes' => () => _loadVotes(),
        'solved' => () => _loadSolved(),
        _ => () => _loadActions(filter),
      };
      return ErrorView(error: _actionErrors[filter]!, onRetry: retry);
    }
    // 总结 tab
    if (filter == 'summary') {
      return _buildSummaryTab();
    }
    // 回应列表使用单独的逻辑
    if (filter == 'reactions') {
      return _buildReactionList();
    }
    // Boost 列表
    if (filter == 'boosts') {
      return _buildBoostList();
    }
    // 投票话题列表
    if (filter == 'votes') {
      return _buildVotesList();
    }
    // 已解决列表
    if (filter == 'solved') {
      return _buildSolvedList();
    }

    final actions = _actionsCache[filter];
    final isLoading = _loadingCache[filter] == true;
    final hasMore = _hasMoreCache[filter] ?? true;
    final loadMoreCoordinator = _actionLoadMoreCoordinator(filter);

    if (_actionErrors[filter] != null && actions == null) {
      return ErrorView(
        error: _actionErrors[filter]!,
        onRetry: () => _loadActions(filter),
      );
    }

    // 优先检查 loading 状态
    if (isLoading && actions == null) {
      final actionType = int.tryParse(filter);
      final ownPost =
          filter == 'all' ||
          actionType == UserActionType.newTopic ||
          actionType == UserActionType.reply;
      return UserActionListSkeleton(
        type: ownPost
            ? UserActivitySkeletonType.post
            : UserActivitySkeletonType.quoted,
      );
    }

    // 空状态
    if (actions == null || actions.isEmpty) {
      return AppEmptyState(
        icon: const Icon(Symbols.inbox_rounded),
        title: context.l10n.userProfile_noContent,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          final distance =
              notification.metrics.maxScrollExtent -
              notification.metrics.pixels;
          if (loadMoreCoordinator.shouldTriggerForDistance(distance)) {
            _loadMoreActions(filter);
          }
        }
        return false;
      },
      child: ListView.builder(
        key: PageStorageKey('user_${_username}_$filter'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: actions.length + 1,
        itemBuilder: (context, index) {
          if (index == actions.length) {
            return PagedListFooter(
              hasMore: hasMore,
              isLoadingMore: loadMoreCoordinator.isRunning && isLoading,
              isLoadMoreFailed: _loadMoreFailedCache[filter] == true,
              onRetry: () => _loadMoreActions(filter),
            );
          }
          return _buildActionItem(actions[index], (
            index: index,
            count: actions.length,
          ));
        },
      ),
    );
  }

  Widget _buildSummaryTab() {
    if (_summaryError != null) {
      return ErrorView(
        error: _summaryError!,
        stackTrace: _summaryErrorStack,
        onRetry: () => _loadSummary(forceRefresh: true),
      );
    }
    if (_summary == null) {
      return const SingleChildScrollView(child: UserSummaryStatsSkeleton());
    }

    final theme = Theme.of(context);
    final summary = _summary!;

    return ListView(
      key: PageStorageKey('user_${_username}_summary'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        if (summary.canSeeSummaryStats) ...[
          _buildSummaryStats(summary),
          const SizedBox(height: 12),
          SegmentedCardGroup(
            children: [
              ExpansionTile(
                leading: Icon(
                  Symbols.menu_book_rounded,
                  color: context.emphasis.accent,
                ),
                shape: const Border(),
                collapsedShape: const Border(),
                key: PageStorageKey('$_username/reading-stats'),
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                title: Text(context.l10n.userProfile_readingStats),
                children: [
                  _buildSummaryMetric(
                    context.l10n.profileStats_daysVisited,
                    '${summary.daysVisited}',
                  ),
                  _buildSummaryMetric(
                    context.l10n.profileStats_topicsEntered,
                    '${summary.topicsEntered}',
                  ),
                  _buildSummaryMetric(
                    context.l10n.profileStats_postsRead,
                    '${summary.postsReadCount}',
                  ),
                  _buildSummaryMetric(
                    context.l10n.profileStats_timeRead,
                    _readingDuration(summary.timeRead),
                  ),
                  _buildSummaryMetric(
                    context.l10n.profileStats_recentTimeRead,
                    _readingDuration(summary.recentTimeRead),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        _buildSummarySections([
          if (_user?.featuredTopic != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.push_pin_rounded,
                  context.l10n.userProfile_featuredTopic,
                ),
                const SizedBox(height: 8),
                SegmentedCardGroup(
                  children: [
                    _buildSummaryTopicItem(theme, _user!.featuredTopic!),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),
          // 热门话题
          if (summary.topics.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.article_rounded,
                  context.l10n.userProfile_topTopics,
                  onTap: summary.canSeeUserActions
                      ? () => _showActivity('4')
                      : null,
                ),
                const SizedBox(height: 8),
                SegmentedCardGroup(
                  children: [
                    for (final topic in summary.topics)
                      _buildSummaryTopicItem(theme, topic),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),

          // 热门回复
          if (summary.replies.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.chat_bubble_rounded,
                  context.l10n.userProfile_topReplies,
                  onTap: summary.canSeeUserActions
                      ? () => _showActivity('5')
                      : null,
                ),
                const SizedBox(height: 8),
                SegmentedCardGroup(
                  children: [
                    for (final reply in summary.replies)
                      _buildSummaryReplyItem(theme, reply),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),

          // 热门链接
          if (summary.links.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.link_rounded,
                  context.l10n.userProfile_topLinks,
                ),
                const SizedBox(height: 8),
                SegmentedCardGroup(
                  children: [
                    for (final link in summary.links)
                      _buildSummaryLinkItem(theme, link),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),

          // 最多回复至
          if (summary.mostRepliedToUsers.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.reply_rounded,
                  context.l10n.userProfile_mostRepliedTo,
                ),
                const SizedBox(height: 8),
                _buildUserChips(theme, summary.mostRepliedToUsers),
                const SizedBox(height: 20),
              ],
            ),

          // 被谁赞的最多
          if (summary.mostLikedByUsers.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.favorite_rounded,
                  context.l10n.userProfile_mostLikedBy,
                ),
                const SizedBox(height: 8),
                _buildUserChips(theme, summary.mostLikedByUsers),
                const SizedBox(height: 20),
              ],
            ),

          // 赞最多
          if (summary.mostLikedUsers.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.thumb_up_rounded,
                  context.l10n.userProfile_mostLiked,
                ),
                const SizedBox(height: 8),
                _buildUserChips(theme, summary.mostLikedUsers),
                const SizedBox(height: 20),
              ],
            ),

          // 热门类别
          if (summary.topCategories.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.category_rounded,
                  context.l10n.userProfile_topCategories,
                ),
                const SizedBox(height: 8),
                SegmentedCardGroup(
                  children: [
                    for (final category in summary.topCategories)
                      _buildSummaryCategoryItem(theme, category),
                  ],
                ),
                const SizedBox(height: 20),
              ],
            ),

          // 热门徽章
          if (summary.badges.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionHeader(
                  theme,
                  Symbols.military_tech_rounded,
                  context.l10n.userProfile_topBadges,
                  onTap: () => _tabController.animateTo(2),
                ),
                const SizedBox(height: 8),
                _buildBadgeChips(theme, summary.badges),
                const SizedBox(height: 20),
              ],
            ),
        ]),

        // 若所有列表都为空
        if (!summary.canSeeSummaryStats &&
            _user?.featuredTopic == null &&
            summary.topics.isEmpty &&
            summary.replies.isEmpty &&
            summary.links.isEmpty &&
            summary.mostRepliedToUsers.isEmpty &&
            summary.mostLikedByUsers.isEmpty &&
            summary.mostLikedUsers.isEmpty &&
            summary.topCategories.isEmpty &&
            summary.badges.isEmpty)
          AppEmptyState(
            icon: const Icon(Symbols.summarize_rounded),
            title: context.l10n.userProfile_noSummary,
          ),
      ],
    );
  }

  Widget _buildSummarySections(List<Widget> sections) => LayoutBuilder(
    builder: (context, constraints) {
      final wide =
          constraints.maxWidth >= UserProfileWideLayout.minWidth &&
          constraints.maxWidth >=
              MediaQuery.textScalerOf(context).scale(14) * 60;
      if (!wide) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sections,
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var column = 0; column < 2; column++) ...[
            if (column > 0) const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = column; index < sections.length; index += 2)
                    sections[index],
                ],
              ),
            ),
          ],
        ],
      );
    },
  );

  Widget _buildSummaryStats(UserSummary summary) {
    final metrics = [
      (
        summary.topicCount,
        context.l10n.userProfile_statsTopics,
        '4',
        Symbols.article_rounded,
      ),
      (
        summary.postCount,
        context.l10n.userProfile_statsReplies,
        '5',
        Symbols.chat_bubble_rounded,
      ),
      (
        summary.likesReceived,
        context.l10n.userProfile_statsLikes,
        '2',
        Symbols.favorite_rounded,
      ),
      (
        summary.likesGiven,
        context.l10n.profileStats_likesGiven,
        '1',
        Symbols.thumb_up_rounded,
      ),
    ];
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth / MediaQuery.textScalerOf(context).scale(14);
        final columns = available >= 52
            ? 4
            : available >= 14
            ? 2
            : 1;
        return SegmentedCardGroup(
          children: [
            for (var row = 0; row < metrics.length; row += columns)
              IntrinsicHeight(
                child: Row(
                  children: [
                    for (
                      var index = row;
                      index < math.min(row + columns, metrics.length);
                      index++
                    ) ...[
                      if (index > row)
                        VerticalDivider(
                          width: 1,
                          indent: 16,
                          endIndent: 16,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      Expanded(
                        child: InkWell(
                          onTap: _canSeeActivity(metrics[index].$3)
                              ? () => _showActivity(metrics[index].$3)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      metrics[index].$4,
                                      size: 18,
                                      color: context.emphasis.accent,
                                    ),
                                    const Spacer(),
                                    if (_canSeeActivity(metrics[index].$3))
                                      Icon(
                                        Symbols.chevron_right_rounded,
                                        size: 16,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Tooltip(
                                  message: '${metrics[index].$1}',
                                  child: Text(
                                    NumberUtils.formatCount(metrics[index].$1),
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  metrics[index].$2,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  String _readingDuration(int seconds) {
    return seconds >= 3600
        ? context.l10n.time_hours(seconds ~/ 3600)
        : context.l10n.time_minutes(seconds ~/ 60);
  }

  Widget _buildSummaryMetric(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    ThemeData theme,
    IconData icon,
    String title, {
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.emphasis.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onTap != null)
            TextButton(
              onPressed: onTap,
              child: Text(context.l10n.common_viewAll),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryTopicItem(ThemeData theme, SummaryTopic topic) {
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openTopic(topicId: topic.id, initialTitle: topic.title),
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                Icon(
                  Symbols.favorite_rounded,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
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

    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: targetTopicId != null
            ? () => _openTopic(
                topicId: targetTopicId,
                initialTitle: topic?.title,
                scrollToPostNumber: reply.postNumber,
              )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  topic?.title ??
                      context.l10n.userProfile_topicHash(
                        targetTopicId.toString(),
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (reply.likeCount > 0) ...[
                const SizedBox(width: 8),
                Icon(
                  Symbols.favorite_rounded,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
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
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (link.topic != null) {
            _openTopic(
              topicId: link.topic!.id,
              initialTitle: link.topic!.title,
              scrollToPostNumber: link.postNumber,
            );
          } else {
            launchUrl(Uri.parse(link.url));
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Symbols.open_in_new_rounded,
                size: 16,
                color: theme.colorScheme.outline,
              ),
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
      children: users
          .map(
            (user) => InkWell(
              onTap: () =>
                  EmbeddedStackScope.openProfile(context, user.username),
              customBorder: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(20),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: ShapeDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(20),
                  ),
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
                      user.name?.isNotEmpty == true
                          ? user.name!
                          : user.username,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: ShapeDecoration(
                        color: theme.colorScheme.primaryContainer,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: context.shapes.borderRadius(10),
                        ),
                      ),
                      child: Text(
                        '${user.count}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildSummaryCategoryItem(ThemeData theme, SummaryCategory cat) {
    final color = ColorUtils.category(
      cat.color,
      theme,
      fallback: theme.colorScheme.primary,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => openCategoryPage(context, cat.id, useWorkspace: false),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: ShapeDecoration(
                  color: color,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(3),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text(
                          context.l10n.userProfile_catTopicCount(
                            cat.topicCount,
                          ),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          context.l10n.userProfile_catPostCount(cat.postCount),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Symbols.chevron_right_rounded, size: 20),
            ],
          ),
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
            InteractionPageRoute(builder: (_) => BadgePage(badgeId: badge.id)),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: ShapeDecoration(
              gradient: BadgeUIUtils.getBadgeGradient(context, badgeType),
              shape: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(12),
                side: BorderSide(color: color.withValues(alpha: 0.3)),
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
                    fontWeight: FontWeight.w500,
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
      return const UserActionListSkeleton(
        type: UserActivitySkeletonType.reaction,
      );
    }

    // 空状态
    if (reactions == null || reactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.emoji_emotions_rounded,
              size: 48,
              color: context.appColors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noReactions,
              style: TextStyle(color: context.appColors.grey[600]),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          final distance =
              notification.metrics.maxScrollExtent -
              notification.metrics.pixels;
          if (_reactionsLoadMoreCoordinator.shouldTriggerForDistance(
            distance,
          )) {
            _loadMoreReactions();
          }
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: reactions.length + 1,
        itemBuilder: (context, index) {
          if (index == reactions.length) {
            return PagedListFooter(
              hasMore: hasMore,
              isLoadingMore:
                  _reactionsLoadMoreCoordinator.isRunning && isLoading,
              isLoadMoreFailed: _reactionsLoadMoreFailed,
              onRetry: _loadMoreReactions,
            );
          }
          return _buildReactionItem(reactions[index], (
            index: index,
            count: reactions.length,
          ));
        },
      ),
    );
  }

  /// Boost 列表
  Widget _buildBoostList() {
    final boosts = _boostsCache;
    final isLoading = _boostsLoading;
    final hasMore = _boostsHasMore;

    // 优先检查 loading 状态
    if (isLoading && boosts == null) {
      return const UserActionListSkeleton(type: UserActivitySkeletonType.boost);
    }

    // 空状态
    if (boosts == null || boosts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.rocket_launch_rounded,
              size: 48,
              color: context.appColors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noBoosts,
              style: TextStyle(color: context.appColors.grey[600]),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          final distance =
              notification.metrics.maxScrollExtent -
              notification.metrics.pixels;
          if (_boostsLoadMoreCoordinator.shouldTriggerForDistance(distance)) {
            _loadMoreBoosts();
          }
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: boosts.length + 1,
        itemBuilder: (context, index) {
          if (index == boosts.length) {
            return PagedListFooter(
              hasMore: hasMore,
              isLoadingMore: _boostsLoadMoreCoordinator.isRunning && isLoading,
              isLoadMoreFailed: _boostsLoadMoreFailed,
              onRetry: _loadMoreBoosts,
            );
          }
          return _buildBoostItem(boosts[index], (
            index: index,
            count: boosts.length,
          ));
        },
      ),
    );
  }

  /// 投票话题列表
  Widget _buildVotesList() {
    final topics = _votesCache;
    final isLoading = _votesLoading;
    final hasMore = _votesHasMore;
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

    // 优先检查 loading 状态
    if (isLoading && topics == null) {
      return const UserActionListSkeleton(type: UserActivitySkeletonType.topic);
    }

    // 空状态
    if (topics == null || topics.isEmpty) {
      return AppEmptyState(
        icon: const Icon(Symbols.how_to_vote_rounded),
        title: context.l10n.userProfile_noVotes,
      );
    }

    final enableLongPress = ref.watch(
      preferencesProvider.select((p) => p.longPressPreview),
    );
    final categories = ref.watch(categoryMapProvider).value ?? const {};

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          final distance =
              notification.metrics.maxScrollExtent -
              notification.metrics.pixels;
          if (_votesLoadMoreCoordinator.shouldTriggerForDistance(distance)) {
            _loadMoreVotes();
          }
        }
        return false;
      },
      child: ListView.builder(
        padding: padding,
        itemCount: topics.length + 1,
        itemBuilder: (context, index) {
          if (index == topics.length) {
            return PagedListFooter(
              hasMore: hasMore,
              isLoadingMore: _votesLoadMoreCoordinator.isRunning && isLoading,
              isLoadMoreFailed: _votesLoadMoreFailed,
              onRetry: _loadMoreVotes,
            );
          }
          final topic = topics[index];
          void openTopic() => _openTopic(
            topicId: topic.id,
            initialTitle: topic.title,
            scrollToPostNumber: ref.read(preferencesProvider).defaultNestedView
                ? null
                : topic.lastReadPostNumber,
          );
          return MorphingDialogAnchor(
            enabled: enableLongPress,
            bottomGap: index == topics.length - 1
                ? 0
                : SegmentedCardItem.gapOf(context, 4),
            builder: (cardContext) => ActivityTopicCard(
              topic: topic,
              position: (index: index, count: topics.length),
              categories: categories,
              onTap: openTopic,
              onPreviewIntent: enableLongPress
                  ? () => TopicPreviewPreloader.preload(
                      ref.read(discourseServiceProvider),
                      topic.id,
                    )
                  : null,
              onLongPress: enableLongPress
                  ? () => TopicPreviewDialog.show(
                      context,
                      topic: topic,
                      onOpen: openTopic,
                      sourceContext: cardContext,
                      anchorColor: PageBackgroundScope.contentColor(
                        context,
                        Theme.of(context).cardTheme.color ??
                            Theme.of(context).colorScheme.surfaceContainerLow,
                      ),
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }

  /// 已解决列表
  Widget _buildSolvedList() {
    final posts = _solvedCache;
    final isLoading = _solvedLoading;
    final hasMore = _solvedHasMore;

    // 优先检查 loading 状态
    if (isLoading && posts == null) {
      return const UserActionListSkeleton();
    }

    // 空状态
    if (posts == null || posts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.check_circle_rounded,
              size: 48,
              color: context.appColors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noSolved,
              style: TextStyle(color: context.appColors.grey[600]),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical) {
          final distance =
              notification.metrics.maxScrollExtent -
              notification.metrics.pixels;
          if (_solvedLoadMoreCoordinator.shouldTriggerForDistance(distance)) {
            _loadMoreSolved();
          }
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: posts.length + 1,
        itemBuilder: (context, index) {
          if (index == posts.length) {
            return PagedListFooter(
              hasMore: hasMore,
              isLoadingMore: _solvedLoadMoreCoordinator.isRunning && isLoading,
              isLoadMoreFailed: _solvedLoadMoreFailed,
              onRetry: _loadMoreSolved,
            );
          }
          return _buildSolvedItem(posts[index], (
            index: index,
            count: posts.length,
          ));
        },
      ),
    );
  }

  TopicUser get _activityOwner => TopicUser(
    id: _user!.id,
    username: _user!.username,
    name: _user!.name,
    avatarTemplate: _user!.avatarTemplate ?? '',
  );

  Widget _buildBoostItem(UserBoost boost, ({int index, int count}) position) {
    final text = BoostContentParser.parse(boost.cooked).displayText;
    return ActivityPostCard(
      position: position,
      author: boost.author,
      title: boost.topicTitle ?? '',
      actionLabel: context.l10n.userProfile_tabBoosts,
      actionIcon: Symbols.rocket_launch_rounded,
      occurredAt: boost.createdAt,
      postNumber: boost.postNumber,
      excerpt: boost.excerpt,
      categoryId: boost.categoryId,
      categories: ref.watch(categoryMapProvider).value ?? const {},
      boostNote: text.isEmpty
          ? null
          : ActivityBoostNote(actor: _activityOwner, text: text),
      onTap: () => _openTopic(
        topicId: boost.topicId,
        scrollToPostNumber: boost.postNumber,
      ),
    );
  }

  Widget _buildSolvedItem(SolvedPost post, ({int index, int count}) position) =>
      ActivityPostCard(
        position: position,
        author: post.author ?? _activityOwner,
        title: post.topicTitle ?? '',
        actionLabel: context.l10n.post_solutionAccepted,
        actionIcon: Symbols.check_circle_rounded,
        accepted: true,
        occurredAt: post.createdAt,
        postNumber: post.postNumber,
        excerpt: post.excerpt,
        categoryId: post.categoryId,
        categories: ref.watch(categoryMapProvider).value ?? const {},
        onTap: () => _openTopic(
          topicId: post.topicId,
          scrollToPostNumber: post.postNumber,
        ),
      );

  Widget _buildActionItem(
    UserAction action,
    ({int index, int count}) position,
  ) {
    final ownPost =
        action.actionType == UserActionType.newTopic ||
        action.actionType == UserActionType.reply;
    final author = action.author ?? (ownPost ? _activityOwner : null);
    final actor = TopicUser(
      id: 0,
      username: action.username ?? _user!.username,
      avatarTemplate: action.avatarTemplate ?? _user!.avatarTemplate ?? '',
    );
    return ActivityPostCard(
      position: position,
      author: author,
      title: action.title,
      actionLabel: action.actionType == UserActionType.wasLiked
          ? context.l10n.userProfile_actionLike
          : _getActionLabel(action.actionType),
      actionIcon: _getActionIcon(action.actionType),
      actionActor: action.actionType == UserActionType.wasLiked ? actor : null,
      occurredAt: action.actingAt,
      postNumber: action.postNumber,
      excerpt: action.excerpt,
      quoteExcerpt: !ownPost,
      categoryId: action.categoryId,
      categories: ref.watch(categoryMapProvider).value ?? const {},
      onTap: () => _openTopic(
        topicId: action.topicId,
        scrollToPostNumber: action.postNumber,
      ),
    );
  }

  Widget _buildReactionItem(
    UserReaction reaction,
    ({int index, int count}) position,
  ) => ActivityPostCard(
    position: position,
    author: reaction.author,
    title: reaction.topicTitle ?? '',
    actionLabel: context.l10n.userProfile_tabReactions,
    occurredAt: reaction.createdAt,
    postNumber: reaction.postNumber,
    excerpt: reaction.excerpt,
    quoteExcerpt: true,
    reactionId: reaction.reactionValue,
    categoryId: reaction.categoryId,
    categories: ref.watch(categoryMapProvider).value ?? const {},
    onTap: () => _openTopic(
      topicId: reaction.topicId,
      scrollToPostNumber: reaction.postNumber,
    ),
  );

  IconData _getActionIcon(int? type) {
    switch (type) {
      case UserActionType.like:
        return Symbols.favorite_rounded;
      case UserActionType.wasLiked:
        return Symbols.favorite_border_rounded;
      case UserActionType.newTopic:
        return Symbols.article_rounded;
      case UserActionType.reply:
        return Symbols.chat_bubble_rounded;
      default:
        return Symbols.history_rounded;
    }
  }

  String _getEmojiUrl(String emojiName) =>
      EmojiHandler().getEmojiUrl(emojiName);

  String _getActionLabel(int? type) {
    switch (type) {
      case UserActionType.like:
        return S.current.userProfile_actionLike;
      case UserActionType.wasLiked:
        return S.current.userProfile_actionLiked;
      case UserActionType.newTopic:
        return S.current.userProfile_actionCreatedTopic;
      case UserActionType.reply:
        return S.current.common_reply;
      default:
        return S.current.userProfile_actionDefault;
    }
  }
}

class _ProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  const _ProfileTabsDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return PageBackdrop(child: child);
  }

  @override
  bool shouldRebuild(_ProfileTabsDelegate oldDelegate) =>
      child != oldDelegate.child;
}
