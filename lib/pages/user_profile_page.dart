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
import '../widgets/common/relative_time_text.dart';
import '../utils/number_utils.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/pagination_helper.dart';
import '../services/emoji_handler.dart';
import 'package:dio/dio.dart';
import '../utils/url_helper.dart';
import '../services/app_error_handler.dart';
import '../utils/share_utils.dart';
import '../providers/preferences_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../utils/platform_utils.dart';
import '../utils/responsive.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/layout/pane_projection_back_scope.dart';
import 'topics_screen.dart' show PaneContentWidget;
import '../widgets/common/flair_badge.dart';
import '../widgets/common/grain_gradient_background.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/paged_list_footer.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/user/avatar_action_menu.dart';
import '../widgets/content/collapsed_html_content.dart';
import '../utils/fluxdo_render_callbacks.dart';
import '../widgets/post/reply_sheet.dart';
import '../widgets/user/user_profile_skeleton.dart';
import '../widgets/user/ignore_duration_picker.dart';
import '../widgets/topic/topic_card_prewarmer.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/post/post_boost/boost_content.dart';
import '../widgets/badge/badge_ui_utils.dart';
import '../services/toast_service.dart';
import '../models/badge.dart' as badge_model;
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import 'follow_list_page.dart';
import 'image_viewer_page.dart';
import 'badge_page.dart';
import 'chat/channel/chat_channel_page.dart';
import 'package:common_ui/common_ui.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import '../widgets/common/hero_image.dart';

/// 用户个人页
/// 头像的展示方式:方形账号是 cover 裁切 + 圆角,圆形账号走 circular。
///
/// 一处给出,同时约束源端与 openViewer 两侧参数(见 ViewerSourceStyle)——
/// 此前两处不同步:源端 borderRadius 12 而 openViewer 传 heroSourceRadius 8。
ViewerSourceStyle _avatarStyle({required bool isSquare, required double radius}) =>
    isSquare
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
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  User? _user;
  UserSummary? _summary;
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
      selectedUserProfilePaneProvider(widget.username);

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
      ref.read(_ownPaneProvider.notifier).select(
            topicId: topicId,
            initialTitle: initialTitle,
            scrollToPostNumber: scrollToPostNumber,
          );
      return;
    }

    final restoreScope = FullScreenPaneRestoreScope.maybeOf(context);
    if (restoreScope != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
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
      MaterialPageRoute(
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

  // tab 对应的 filter: summary=总结, 4,5=全部(话题+回复), 4=话题, 5=回复, 1=点赞,
  // reactions=回应, boosts=Boost, votes=投票, solved=已解决
  static const List<String> _tabFilters = [
    'summary',
    '4,5',
    '4',
    '5',
    '1',
    'reactions',
    'boosts',
    'votes',
    'solved',
  ];

  /// 桌面端 Esc 关闭当前层:平行视界嵌入层走 onEmbeddedBack,普通路由
  /// maybePop —— 与 TopicDetailPage 的 closeOverlay 语义对齐。
  late final ShortcutScopeBinding _shortcutScopeBinding = ShortcutScopeBinding(
    ref: ref,
    scope: widget.embeddedMode ? ShortcutScope.detail : ShortcutScope.context,
    // 嵌入面板挂在 IndexedStack 常驻 tab 里:宿主不活跃时注册失效,
    // 否则截胡其他 tab 的 ESC(见 TopicDetailPage 同注)。
    enabled: () => !widget.embeddedMode || widget.parentActive,
  );

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
    _registerShortcuts();
    _tabController = TabController(length: _tabFilters.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    // 预先为所有 tab 设置 loading 状态，避免切换时闪现空状态
    for (final filter in _tabFilters) {
      if (filter == 'summary') {
        // 总结 tab 数据随 _summary 加载，无需单独标记
      } else if (filter == 'reactions') {
        _reactionsLoading = true;
      } else if (filter == 'boosts') {
        _boostsLoading = true;
      } else if (filter == 'votes') {
        _votesLoading = true;
      } else if (filter == 'solved') {
        _solvedLoading = true;
      } else {
        _loadingCache[filter] = true;
      }
    }
    _loadUser();
  }

  @override
  void dispose() {
    _shortcutScopeBinding.disposeDeferred();
    _standaloneEsc?.dispose();
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
      } else if (filter == 'boosts') {
        if (_boostsCache == null) {
          _loadBoosts();
        }
      } else if (filter == 'votes') {
        if (_votesCache == null) {
          _loadVotes();
        }
      } else if (filter == 'solved') {
        if (_solvedCache == null) {
          _loadSolved();
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
    } catch (e, s) {
      if (mounted) {
        setState(() {
          _error = e;
          _errorStack = s;
          _isLoading = false;
        });
      }
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
        MaterialPageRoute(
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
    if (_user == null) return;

    final hasBio = _user!.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user!.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user!.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user!.createdAt != null;
    final isSuspended = _user!.isSuspended;
    final isSilenced = _user!.isSilenced;

    if (!hasBio &&
        !hasLocation &&
        !hasWebsite &&
        !hasJoinedAt &&
        !isSuspended &&
        !isSilenced) {
      return;
    }

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
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
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
                          fontWeight: FontWeight.w600,
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 24,
                    ),
                    children: [
                      // 封禁/禁言状态
                      if (isSuspended)
                        _buildRestrictionSection(
                          theme,
                          icon: Symbols.block_rounded,
                          title: context.l10n.userProfile_suspendedStatus,
                          label: _user!.isSuspendedForever
                              ? context.l10n.userProfile_permanentlySuspended
                              : context.l10n.userProfile_suspendedUntil(
                                  TimeUtils.formatFullDate(
                                    _user!.suspendedTill,
                                  ),
                                ),
                          reason: _user!.suspendReason,
                          color: theme.colorScheme.error,
                        ),
                      if (isSilenced)
                        _buildRestrictionSection(
                          theme,
                          icon: Symbols.mic_off_rounded,
                          title: context.l10n.userProfile_silencedStatus,
                          label: _user!.isSilencedForever
                              ? context.l10n.userProfile_permanentlySilenced
                              : context.l10n.userProfile_silencedUntil(
                                  TimeUtils.formatFullDate(_user!.silencedTill),
                                ),
                          reason: _user!.silenceReason,
                          color: Colors.orange,
                        ),

                      // 个人简介
                      if (hasBio) ...[
                        Text(
                          context.l10n.userProfile_bio,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        // 个人简介属只读展示：走新引擎 FluxdoRender，关闭划词选区。
                        FluxdoRenderCallbacks.generic(
                          heroTagNamespace:
                              'user_profile_bio_${_user!.username}',
                        ).render(
                          cookedHtml: _user!.bio!,
                          baseTextStyle: theme.textTheme.bodyLarge?.copyWith(
                            height: 1.6,
                          ),
                          selectionEnabled: false,
                        ),
                        const SizedBox(height: 32),
                      ],

                      // 其他信息列表
                      if (hasLocation || hasWebsite || hasJoinedAt) ...[
                        Text(
                          context.l10n.userProfile_moreInfo,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),

                        if (hasLocation)
                          _buildInfoRow(
                            context,
                            Symbols.location_on_rounded,
                            context.l10n.userProfile_location,
                            _user!.location!,
                          ),

                        if (hasWebsite)
                          _buildInfoRow(
                            context,
                            Symbols.link_rounded,
                            context.l10n.userProfile_website,
                            _user!.websiteName ?? _user!.website!,
                            url: _user!.website,
                            isLink: true,
                          ),

                        if (hasJoinedAt)
                          _buildInfoRow(
                            context,
                            Symbols.calendar_today_rounded,
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
              fontWeight: FontWeight.w600,
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
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
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
    });

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
          }
        });
      }
    }
  }

  Future<void> _loadReactions({bool loadMore = false}) async {
    if (_reactionsLoading && _reactionsCache != null) return;

    if (!loadMore) {
      _reactionsLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
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
        widget.username,
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
          }
        });
      }
    }
  }

  Future<void> _loadBoosts({bool loadMore = false}) async {
    if (_boostsLoading && _boostsCache != null) return;

    if (!loadMore) {
      _boostsLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
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
        widget.username,
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
          }
        });
      }
    }
  }

  Future<void> _loadVotes({bool loadMore = false}) async {
    if (_votesLoading && _votesCache != null) return;

    if (!loadMore) {
      _votesLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _votesLoading = true;
      _votesLoadMoreFailed = false;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final page = loadMore ? _votesPage + 1 : 0;
      final response = await service.getVotedTopics(
        widget.username,
        page: page,
      );

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
          }
        });
      }
    }
  }

  Future<void> _loadSolved({bool loadMore = false}) async {
    if (_solvedLoading && _solvedCache != null) return;

    if (!loadMore) {
      _solvedLoadMoreCoordinator.resetCooldown();
    }

    setState(() {
      _solvedLoading = true;
      _solvedLoadMoreFailed = false;
    });

    try {
      final service = ref.read(discourseServiceProvider);
      final offset = loadMore ? (_solvedCache?.length ?? 0) : 0;
      final response = await service.getUserSolvedPosts(
        widget.username,
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
    // 话题卡自定义样式:改设置触发 rebuild(投票 tab 的话题卡直读全局快照)
    ref.watch(preferencesProvider.select((p) => p.topicCardStyle));

    if (_isLoading) {
      return const UserProfileSkeleton();
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.username),
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

    // 计算 pinned header 高度
    final double pinnedHeaderHeight =
        kToolbarHeight +
        MediaQuery.of(context).padding.top +
        36; // 36 是 TabBar 高度

    // 宽窄两版排版按**本页实际可用宽度**分流(不是屏宽):嵌入面板、
    // 压栈后收窄的左栏拿到的都是格子宽,窄了自动回竖版折叠头图形态。
    final Widget profileBody = LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= UserProfileWideLayout.minWidth) {
          return _buildWideBody(theme, currentUser);
        }
        return _buildNarrowBody(theme, currentUser, pinnedHeaderHeight);
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
        child: _constrainWide(_buildActionList(filter)),
      );
    }).toList();
  }

  /// 竖版(窄):折叠头图 SliverAppBar + Tab 列表(原形态)。
  Widget _buildNarrowBody(
    ThemeData theme,
    User? currentUser,
    double pinnedHeaderHeight,
  ) {
    return Scaffold(
      body: ScrollConfiguration(
        // 禁用 overscroll indicator：Material 3 在 Android 上默认
        // StretchingOverscrollIndicator，与 NestedScrollView/SliverAppBar
        // 组合存在 framework bug（flutter/flutter #100967、#116522、#100538），
        // 表现为上滑松手时 tab 区域回弹抖动（与 topics_page 同因同修）。
        behavior: ScrollConfiguration.of(
          context,
        ).copyWith(scrollbars: false, overscroll: false),
        child: ExtendedNestedScrollView(
          controller: _scrollController,
          pinnedHeaderSliverHeightBuilder: () => pinnedHeaderHeight,
          onlyOneScrollInBody: true,
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            _buildSliverAppBar(context, theme, currentUser),
          ],
          body: TabBarView(
            controller: _tabController,
            children: _buildTabViews(),
          ),
        ),
      ),
    );
  }

  /// 宽版:左侧定宽资料栏(头图背景+用户信息全量常驻)+ 右侧 Tab 与
  /// 列表占满剩余宽度。竖版的「头图占满首屏再折叠」在宽屏下浪费一整
  /// 屏高度、内容被挤成一条,信息与内容改并排才用得上横向空间。
  Widget _buildWideBody(ThemeData theme, User? currentUser) {
    final isOwnProfile =
        currentUser != null &&
        _user != null &&
        currentUser.username == _user!.username;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: UserProfileWideLayout.infoPanelWidth,
            child: _buildWideInfoPanel(theme, currentUser, isOwnProfile),
          ),
          SizedBox(
            width: 1,
            child: ColoredBox(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                // Tab 行与列表同一条限宽轴线,避免"标签顶在左上角、
                // 内容居中"的错位感。
                Material(
                  color: theme.scaffoldBackgroundColor,
                  child: SafeArea(
                    bottom: false,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: Breakpoints.maxContentWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _buildTabBar(theme),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: _buildTabViews(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 宽版左栏:顶部头图横幅 + 头像骑缝叠在横幅下缘,下方信息用主题
  /// 配色正常排版。竖版那套「白字压满幅头图」平铺到整栏全高会把左栏
  /// 闷成一大块深色(实测被否),头图只作横幅、信息区回到正常底色。
  Widget _buildWideInfoPanel(
    ThemeData theme,
    User? currentUser,
    bool isOwnProfile,
  ) {
    final bgUrl = _user?.backgroundUrl;
    final hasBackground = bgUrl != null && bgUrl.isNotEmpty;
    const bannerHeight = UserProfileWideLayout.bannerHeight;
    const avatarRadius = UserProfileWideLayout.avatarRadius;
    final hasBio = _user?.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user?.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user?.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user?.createdAt != null;
    final hasInfo = hasBio || hasLocation || hasWebsite || hasJoinedAt;

    final banner = SizedBox(
      height: bannerHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 个人主页可能长时间停留,装饰背景不常驻刷新(与竖版同口径)。
          const GrainGradientBackground(animated: false),
          if (hasBackground)
            Image(
              image: discourseImageProvider(UrlHelper.resolveUrlWithCdn(bgUrl)),
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
          // 轻压暗:保住悬浮按钮可读性,不吃头图本身。
          Container(color: Colors.black.withValues(alpha: 0.2)),
        ],
      ),
    );

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      banner,
                      Positioned(
                        left: 20,
                        bottom: -avatarRadius,
                        child: _buildTappableAvatar(
                          radius: avatarRadius,
                          flairSize: 34,
                          flairRight: -8,
                          flairBottom: -4,
                          borderColor: theme.scaffoldBackgroundColor,
                          borderWidth: 4,
                        ),
                      ),
                    ],
                  ),
                  // 头像下半部分的骑缝空间,右侧顺势放关注按钮。
                  SizedBox(
                    height: avatarRadius + 12,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 20),
                        child: _buildWideFollowButton(isOwnProfile),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                (_user?.name?.isNotEmpty == true)
                                    ? _user!.name!
                                    : (_user?.username ?? ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (_user?.status != null) ...[
                              const SizedBox(width: 8),
                              _buildStatusEmoji(_user!.status!),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (_user?.username != null)
                              Flexible(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => copyUsernameToClipboard(
                                    _user!.username,
                                  ),
                                  child: Text(
                                    '@${_user!.username}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _getTrustLevelLabel(_user?.trustLevel ?? 0),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // 封禁/禁言与简介互斥(与竖版一致)。
                        if (_user!.isSuspended || _user!.isSilenced) ...[
                          GestureDetector(
                            onTap: _showUserInfo,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_user!.isSuspended) ...[
                                  _buildRestrictionBanner(
                                    icon: Symbols.block_rounded,
                                    label: _user!.isSuspendedForever
                                        ? context
                                              .l10n
                                              .userProfile_suspendedBannerForever
                                        : context.l10n
                                              .userProfile_suspendedBannerUntil(
                                                TimeUtils.formatFullDate(
                                                  _user!.suspendedTill,
                                                ),
                                              ),
                                    reason: _user!.suspendReason,
                                    color: Colors.redAccent,
                                    reasonColor:
                                        theme.colorScheme.onSurfaceVariant,
                                  ),
                                  if (_user!.isSilenced)
                                    const SizedBox(height: 8),
                                ],
                                if (_user!.isSilenced)
                                  _buildRestrictionBanner(
                                    icon: Symbols.mic_off_rounded,
                                    label: _user!.isSilencedForever
                                        ? context
                                              .l10n
                                              .userProfile_silencedBannerForever
                                        : context.l10n
                                              .userProfile_silencedBannerUntil(
                                                TimeUtils.formatFullDate(
                                                  _user!.silencedTill,
                                                ),
                                              ),
                                    reason: _user!.silenceReason,
                                    color: Colors.orangeAccent,
                                    reasonColor:
                                        theme.colorScheme.onSurfaceVariant,
                                  ),
                              ],
                            ),
                          ),
                        ] else
                          InkWell(
                            onTap: hasInfo ? _showUserInfo : null,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: hasBio
                                        ? CollapsedHtmlContent(
                                            html: _user!.bio!,
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                            textStyle: theme
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(height: 1.4),
                                          )
                                        : Text(
                                            context.l10n.userProfile_noBio,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                  fontStyle: FontStyle.italic,
                                                ),
                                          ),
                                  ),
                                  if (hasInfo) ...[
                                    const SizedBox(width: 8),
                                    Icon(
                                      Symbols.chevron_right_rounded,
                                      size: 16,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        _buildWideStats(theme),
                        if (_user?.lastPostedAt != null ||
                            _user?.lastSeenAt != null) ...[
                          const SizedBox(height: 20),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Symbols.flash_on_rounded,
                                size: 14,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              RelativeTimeText(
                                dateTime:
                                    _user?.lastSeenAt ?? _user!.lastPostedAt!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 悬浮顶栏:返回 + 操作按钮,渐变黑纱保证压图可读。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black45, Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: IconTheme(
                    data: const IconThemeData(color: Colors.white),
                    child: Row(
                      children: [
                        // 与竖版 AppBar 同一套返回键语义:嵌入预览位
                        // (onEmbeddedBack == null)不渲染任何返回键。
                        if (!widget.embeddedMode)
                          const BackButton(color: Colors.white)
                        else if (widget.onEmbeddedBack != null)
                          BackButton(
                            color: Colors.white,
                            onPressed: widget.onEmbeddedBack,
                          ),
                        const Spacer(),
                        ..._buildHeaderActions(isOwnProfile),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
        decoration: BoxDecoration(
          shape: isSquare ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: isSquare ? BorderRadius.circular(12) : null,
          border: Border.all(color: borderColor, width: borderWidth),
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
            ),
          ),
        ),
      ),
    );
  }

  /// 宽版关注按钮:主题配色(竖版那颗白底按钮是压深色头图的样式,
  /// 放到正常底色上会糊)。
  Widget _buildWideFollowButton(bool isOwnProfile) {
    if (_user == null || _user!.canFollow != true || isOwnProfile) {
      return const SizedBox.shrink();
    }
    if (_isFollowLoading) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: EdgeInsets.all(6),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return _isFollowed
        ? FilledButton.tonalIcon(
            onPressed: _toggleFollow,
            icon: const Icon(Symbols.check_rounded, size: 16),
            label: Text(context.l10n.userProfile_followed),
          )
        : FilledButton.icon(
            onPressed: _toggleFollow,
            icon: const Icon(Symbols.add_rounded, size: 16),
            label: Text(context.l10n.userProfile_follow),
          );
  }

  /// 宽版统计区:数值大字+标签小字上下排,Wrap 流式铺开(竖版的
  /// 单行小字挤排是为头图区省高度,左栏不缺纵向空间)。
  Widget _buildWideStats(ThemeData theme) {
    final items = <Widget>[
      if (_user?.totalFollowing != null)
        _buildWideStat(
          NumberUtils.formatCount(_user!.totalFollowing!),
          context.l10n.userProfile_following,
          _user!.totalFollowing!,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FollowListPage(
                username: widget.username,
                isFollowing: true,
              ),
            ),
          ),
        ),
      if (_user?.totalFollowers != null)
        _buildWideStat(
          NumberUtils.formatCount(_user!.totalFollowers!),
          context.l10n.userProfile_followers,
          _user!.totalFollowers!,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FollowListPage(
                username: widget.username,
                isFollowing: false,
              ),
            ),
          ),
        ),
      if (_summary != null) ...[
        _buildWideStat(
          NumberUtils.formatCount(_summary!.likesReceived),
          context.l10n.userProfile_statsLikes,
          _summary!.likesReceived,
        ),
        _buildWideStat(
          NumberUtils.formatCount(_summary!.daysVisited),
          context.l10n.userProfile_statsVisits,
          _summary!.daysVisited,
        ),
        _buildWideStat(
          NumberUtils.formatCount(_summary!.topicCount),
          context.l10n.userProfile_statsTopics,
          _summary!.topicCount,
        ),
        _buildWideStat(
          NumberUtils.formatCount(_summary!.postCount),
          context.l10n.userProfile_statsReplies,
          _summary!.postCount,
        ),
      ],
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 28, runSpacing: 16, children: items);
  }

  Widget _buildWideStat(
    String value,
    String label,
    int rawValue, {
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Tooltip(
      message: '$rawValue',
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: content,
            ),
    );
  }

  /// 全屏形态的平行视界宿主组装:栈空=资料页独占全宽(自己的宽屏
  /// 排版,无右栏空白);点话题/回复=资料页收窄成左栏、详情从右滑入
  /// (对半分);缩窄=详情转投影;窄屏点列表=真路由。
  Widget _wrapStandaloneHost(Widget profileBody) {
    final selected = ref.watch(_ownPaneProvider);

    // ESC 两段式:右栏开着让分发落 detail scope(关右栏),空了才
    // maybePop 关整页。
    (_standaloneEsc ??= PaneHostEscBinding(ref: ref))
        .sync(context, paneOpen: selected.hasSelection);

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

  Widget _buildSliverAppBar(
    BuildContext context,
    ThemeData theme,
    User? currentUser,
  ) {
    final bgUrl = _user?.backgroundUrl;
    final hasBackground = bgUrl != null && bgUrl.isNotEmpty;
    // Standard toolbar height is usually 56.0 + status bar height
    final double pinnedHeight =
        kToolbarHeight + MediaQuery.of(context).padding.top;
    // 横屏时屏幕高度有限，限制 expandedHeight 不超过屏幕高度的 70%
    final screenHeight = MediaQuery.of(context).size.height;
    final double expandedHeight = 410.0.clamp(0.0, screenHeight * 0.7);
    // 头部完整内容(头像行+简介卡+双行统计+活跃胶囊)加底部间距约需 340px;
    // 横屏被上面限高后装不下,开精简模式(隐简介卡/活跃胶囊)——否则自底
    // 锚定的内容向上溢出,与 toolbar 返回键/操作按钮及状态栏叠印。
    final bool compactHeader = expandedHeight < 340;
    // 检查是否是自己
    final isOwnProfile =
        currentUser != null &&
        _user != null &&
        currentUser.username == _user!.username;

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      stretch: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor:
          Colors.transparent, // Transparent to show FlexibleSpaceBar background
      surfaceTintColor: Colors.transparent, // Prevent M3 tint
      iconTheme: const IconThemeData(color: Colors.white),
      // 同上（错误态 AppBar）的注释：onEmbeddedBack 为空时不能塞
      // BackButton，且要显式关掉 automaticallyImplyLeading。
      automaticallyImplyLeading: !widget.embeddedMode,
      leading: widget.embeddedMode && widget.onEmbeddedBack != null
          ? BackButton(onPressed: widget.onEmbeddedBack)
          : null,
      actions: _buildHeaderActions(isOwnProfile),
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
            child: _buildTabBar(theme),
          ),
        ),
      ),
      // Use a Stack to ensure a solid black background exists BEHIND the FlexibleSpaceBar
      flexibleSpace: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final currentHeight = constraints.biggest.height;
          final t =
              ((currentHeight - pinnedHeight) / (expandedHeight - pinnedHeight))
                  .clamp(0.0, 1.0);

          // 标题透明度：收起时显示（当 t < 0.3 时完全显示，避免半透明）
          final titleOpacity = t < 0.3
              ? 1.0
              : (1.0 - ((t - 0.3) / 0.7)).clamp(0.0, 1.0);
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
                      // 个人主页可能长时间停留，装饰背景不应常驻 60 FPS
                      // 刷新；固定 shader 时间轴仍保留原始画质与噪声细节。
                      child: const GrainGradientBackground(animated: false),
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
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
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
                  Colors.black.withValues(alpha: 0.6), // 展开状态：默认更暗 (0.6)
                  Colors.black.withValues(alpha: 0.85), // 收起状态：稍微透一点 (0.85)
                  Curves.easeOut.transform(1.0 - t), // 使用 easeOut 曲线优化滑动体验
                ),
              ),

              // ===== 层 2: 用户信息内容 - 展开时显示，收起时淡出 =====
              // 宽屏时信息区与下方列表同宽限居中(头图背景仍全宽出血)。
              Positioned(
                left: 20,
                right: 20,
                // TabBar 高度 + 间距(精简模式收紧间距,给内容让位)
                bottom: 36 + (compactHeader ? 12 : 24),
                child: Opacity(
                  opacity: contentOpacity,
                  child: _buildUserInfoContent(
                    theme,
                    currentUser,
                    compact: compactHeader,
                  ),
                ),
              ),

              // ===== 层 3: 收起时的标题栏内容 - 收起时显示，点击展开 =====
              Positioned(
                left: 60 + MediaQuery.of(context).padding.left, // 横屏时需加上左侧安全区
                right: 48 + MediaQuery.of(context).padding.right, // 横屏时需加上右侧安全区
                bottom: 14 + 36, // 调整位置适应 TabBar (36是TabBar高度)
                child: GestureDetector(
                  onTap: titleOpacity > 0.5
                      ? () {
                          _scrollController.animateTo(
                            0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        }
                      : null,
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
                            (_user?.name?.isNotEmpty == true)
                                ? _user!.name!
                                : (_user?.username ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
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
        },
      ),
    );
  }


  /// 用户信息列(头像/名字/简介/统计/最近活动),窄版 SliverAppBar
  /// flexibleSpace 层2 专用(白字压深色头图);宽版左栏是同风格的另一
  /// 套排版(见 _buildWideInfoPanel),两边各自维护。
  ///
  /// [compact] 精简模式(横屏等 flexibleSpace 高度受限时):隐藏简介卡/
  /// 封禁条与最近活跃胶囊,只留头像行+统计,防止内容向上溢出叠到
  /// toolbar/状态栏。
  Widget _buildUserInfoContent(
    ThemeData theme,
    User? currentUser, {
    bool compact = false,
  }) {
    final hasBio = _user?.bio != null && _user!.bio!.isNotEmpty;
    final hasLocation = _user?.location != null && _user!.location!.isNotEmpty;
    final hasWebsite = _user?.website != null && _user!.website!.isNotEmpty;
    final hasJoinedAt = _user?.createdAt != null;
    final hasInfo = hasBio || hasLocation || hasWebsite || hasJoinedAt;
    final isOwnProfile =
        currentUser != null &&
        _user != null &&
        currentUser.username == _user!.username;
    return Column(
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
                  final avatarUrl = _user!.getAvatarUrl(
                    size: 360,
                  );
                  // 与页面头像同参(144)的缩略图作飞行纹理,命中已解码缓存
                  final thumbUrl = _user!.getAvatarUrl(size: 144);
                  // 与源端同源(同竖版口径,见 _avatarStyle)
                  final args = _avatarStyle(
                    isSquare: isSquareAvatarUrl(thumbUrl),
                    radius: 12,
                  ).openViewerArgs;
                  ImageViewerPage.open(
                    context,
                    avatarUrl,
                    heroTag: 'user_avatar_${_user!.username}',
                    thumbnailUrl: thumbUrl,
                    heroSourceFit: args.fit,
                    heroSourceRadius: args.radius,
                    heroSourceCircular: args.circular,
                  );
                }
              },
              child: Builder(
                builder: (context) {
                  // linux.do 站点定制:个别账号头像方形化,外层白边框
                  // 得跟 SmartAvatar 里的裁切形状对齐,不然会出现
                  // "图是方的、外层白圈还是圆的"这种两层错位。
                  final avatarUrl = _user?.getAvatarUrl(size: 144);
                  final isSquare = isSquareAvatarUrl(avatarUrl);
                  return Container(
                    decoration: BoxDecoration(
                      shape: isSquare
                          ? BoxShape.rectangle
                          : BoxShape.circle,
                      borderRadius: isSquare
                          ? BorderRadius.circular(8)
                          : null,
                      border: Border.all(
                        color: Colors.white,
                        width: 2,
                      ),
                    ),
                    child: AvatarWithFlair(
                      flairSize: 30,
                      flairRight: -7,
                      flairBottom: -4,
                      flairUrl: _user?.flairUrl,
                      flairName: _user?.flairName,
                      flairBgColor: _user?.flairBgColor,
                      flairColor: _user?.flairColor,
                      // HeroImage 统一件(同竖版口径)
                      avatar: HeroImage(
                        heroTag: 'user_avatar_${_user?.username ?? ''}',
                        style: _avatarStyle(isSquare: isSquare, radius: 12),
                        flightImage: avatarUrl == null
                            ? null
                            : discourseImageProvider(avatarUrl),
                        child: SmartAvatar(
                          imageUrl: avatarUrl,
                          radius: 36,
                          fallbackText: _user?.username,
                        ),
                      ),
                    ),
                  );
                },
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
                          (_user?.name?.isNotEmpty == true)
                              ? _user!.name!
                              : (_user?.username ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(
                                color: Colors.black45,
                                offset: Offset(0, 1),
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_user?.status != null) ...[
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _buildStatusEmoji(
                            _user!.status!,
                          ),
                        ),
                      ],
                    ],
                  ),

                  // Row 2: Username
                  if (_user?.username != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: 2,
                        bottom: 6,
                      ),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        // 点击 @username 复制用户名
                        onTap: () => copyUsernameToClipboard(
                          _user!.username,
                        ),
                        child: Text(
                          '@${_user?.username}',
                          style: TextStyle(
                            color: Colors.white.withValues(
                              alpha: 0.85,
                            ),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 6), // 占位
                  // Row 3: Level Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _getTrustLevelLabel(_user?.trustLevel ?? 0),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
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
        // 封禁/禁言状态 与 个人简介 互斥显示（与 Discourse 前端一致）。
        // 精简模式整块隐藏——简介与封禁详情仍可从「关于」弹窗查看。
        if (!compact && (_user!.isSuspended || _user!.isSilenced)) ...[
          GestureDetector(
            onTap: _showUserInfo,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封禁提示
                if (_user!.isSuspended) ...[
                  _buildRestrictionBanner(
                    icon: Symbols.block_rounded,
                    label: _user!.isSuspendedForever
                        ? context
                              .l10n
                              .userProfile_suspendedBannerForever
                        : context.l10n
                              .userProfile_suspendedBannerUntil(
                                TimeUtils.formatFullDate(
                                  _user!.suspendedTill,
                                ),
                              ),
                    reason: _user!.suspendReason,
                    color: Colors.redAccent,
                  ),
                  if (_user!.isSilenced)
                    const SizedBox(height: 8),
                ],
                // 禁言提示
                if (_user!.isSilenced)
                  _buildRestrictionBanner(
                    icon: Symbols.mic_off_rounded,
                    label: _user!.isSilencedForever
                        ? context
                              .l10n
                              .userProfile_silencedBannerForever
                        : context.l10n
                              .userProfile_silencedBannerUntil(
                                TimeUtils.formatFullDate(
                                  _user!.silencedTill,
                                ),
                              ),
                    reason: _user!.silenceReason,
                    color: Colors.orangeAccent,
                  ),
              ],
            ),
          ),
        ] else if (!compact) ...[
          // 个人简介（非封禁/禁言状态时显示）
          const SizedBox(height: 12),
          GestureDetector(
            onTap: hasInfo ? _showUserInfo : null,
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
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
                              color: Colors.white.withValues(
                                alpha: 0.9,
                              ),
                              fontSize: 14,
                              height: 1.3,
                            ),
                          )
                        : Text(
                            context.l10n.userProfile_noBio,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(
                                alpha: 0.5,
                              ),
                              fontSize: 14,
                              height: 1.3,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                  ),
                  if (hasInfo) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Symbols.chevron_right_rounded,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.6),
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
              if (_user?.totalFollowing != null ||
                  _user?.totalFollowers != null)
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
                        child: _buildStatSlot(
                          NumberUtils.formatCount(
                            _user!.totalFollowing!,
                          ),
                          context.l10n.userProfile_following,
                          _user!.totalFollowing!,
                        ),
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
                        child: _buildStatSlot(
                          NumberUtils.formatCount(
                            _user!.totalFollowers!,
                          ),
                          context.l10n.userProfile_followers,
                          _user!.totalFollowers!,
                        ),
                      ),
                  ],
                ),
              // 第二行：获赞、访问、话题、回复
              if (_user?.totalFollowing != null ||
                  _user?.totalFollowers != null)
                const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                children: [
                  _buildStatSlot(
                    NumberUtils.formatCount(
                      _summary!.likesReceived,
                    ),
                    context.l10n.userProfile_statsLikes,
                    _summary!.likesReceived,
                  ),
                  _buildStatSlot(
                    NumberUtils.formatCount(
                      _summary!.daysVisited,
                    ),
                    context.l10n.userProfile_statsVisits,
                    _summary!.daysVisited,
                  ),
                  _buildStatSlot(
                    NumberUtils.formatCount(_summary!.topicCount),
                    context.l10n.userProfile_statsTopics,
                    _summary!.topicCount,
                  ),
                  _buildStatSlot(
                    NumberUtils.formatCount(_summary!.postCount),
                    context.l10n.userProfile_statsReplies,
                    _summary!.postCount,
                  ),
                ],
              ),
            ],
          ),

        // 最近活动时间(精简模式隐藏)
        if (!compact &&
            (_user?.lastPostedAt != null || _user?.lastSeenAt != null)) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Symbols.flash_on_rounded,
                  size: 12,
                  color: Colors.white70,
                ),
                const SizedBox(width: 4),
                RelativeTimeText(
                  dateTime:
                      _user?.lastSeenAt ?? _user!.lastPostedAt!,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Tab 栏本体(样式统一)。窄版挂在 SliverAppBar.bottom 的圆角容器里,
  /// 宽版直接放右栏顶部。
  Widget _buildTabBar(ThemeData theme) {
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
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
        Tab(height: 36, text: context.l10n.userProfile_tabBoosts),
        Tab(height: 36, text: context.l10n.userProfile_tabVotes),
        Tab(height: 36, text: context.l10n.userProfile_tabSolved),
      ],
    );
  }

  /// 顶部操作按钮(搜索/私信/聊天/更多)。窄版在 SliverAppBar.actions,
  /// 宽版在左侧资料栏顶行。
  List<Widget> _buildHeaderActions(bool isOwnProfile) {
    return <Widget>[
      IconButton(
        icon: const Icon(Symbols.search_rounded),
        onPressed: () => _openUserSearch(),
      ),
      if (_user != null && _user!.canSendPrivateMessageToUser != false)
        IconButton(
          onPressed: _openMessageDialog,
          icon: const Icon(Symbols.mail_rounded),
          tooltip: context.l10n.userProfile_message,
        ),
      if (_user != null && !isOwnProfile)
        IconButton(
          onPressed: _isStartingChat ? null : _startChat,
          icon: const Icon(Symbols.forum_rounded),
          tooltip: context.l10n.chat_title,
        ),
      SwipeDismissiblePopupMenuButton<String>(
        icon: const Icon(Symbols.more_vert_rounded),
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
                  Icon(
                    Symbols.info_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurface,
                  ),
                  const SizedBox(width: 12),
                  Text(context.l10n.common_about),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'share',
              child: Row(
                children: [
                  Icon(
                    Symbols.share_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurface,
                  ),
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
                        color: theme.colorScheme.primary,
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
                          color: theme.colorScheme.primary,
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
                          color: theme.colorScheme.primary,
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
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
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
              _isFollowed ? Symbols.check_rounded : Symbols.add_rounded,
              size: 16,
            ),
            label: Text(
              _isFollowed
                  ? context.l10n.userProfile_followed
                  : context.l10n.userProfile_follow,
            ),
            style: TextButton.styleFrom(
              backgroundColor: _isFollowed
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.white,
              foregroundColor: _isFollowed ? Colors.white : Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: _isFollowed
                    ? const BorderSide(color: Colors.white38)
                    : BorderSide.none,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
  }

  Widget _buildRestrictionBanner({
    required IconData icon,
    required String label,
    required String? reason,
    required Color color,
    Color? reasonColor,
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

  Widget _buildActionList(String filter) {
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
            Icon(Symbols.inbox_rounded, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noContent,
              style: TextStyle(color: Colors.grey[600]),
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
          if (loadMoreCoordinator.shouldTriggerForDistance(distance)) {
            _loadMoreActions(filter);
          }
        }
        return false;
      },
      child: M3eRefreshIndicator(
        onRefresh: () => _loadActions(filter),
        child: ListView.builder(
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
          _buildSectionHeader(
            theme,
            Symbols.article_rounded,
            context.l10n.userProfile_topTopics,
          ),
          const SizedBox(height: 8),
          ...summary.topics.map(
            (topic) => _buildSummaryTopicItem(theme, topic),
          ),
          const SizedBox(height: 20),
        ],

        // 热门回复
        if (summary.replies.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.chat_bubble_rounded,
            context.l10n.userProfile_topReplies,
          ),
          const SizedBox(height: 8),
          ...summary.replies.map(
            (reply) => _buildSummaryReplyItem(theme, reply),
          ),
          const SizedBox(height: 20),
        ],

        // 热门链接
        if (summary.links.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.link_rounded,
            context.l10n.userProfile_topLinks,
          ),
          const SizedBox(height: 8),
          ...summary.links.map((link) => _buildSummaryLinkItem(theme, link)),
          const SizedBox(height: 20),
        ],

        // 最多回复至
        if (summary.mostRepliedToUsers.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.reply_rounded,
            context.l10n.userProfile_mostRepliedTo,
          ),
          const SizedBox(height: 8),
          _buildUserChips(theme, summary.mostRepliedToUsers),
          const SizedBox(height: 20),
        ],

        // 被谁赞的最多
        if (summary.mostLikedByUsers.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.favorite_rounded,
            context.l10n.userProfile_mostLikedBy,
          ),
          const SizedBox(height: 8),
          _buildUserChips(theme, summary.mostLikedByUsers),
          const SizedBox(height: 20),
        ],

        // 赞最多
        if (summary.mostLikedUsers.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.thumb_up_rounded,
            context.l10n.userProfile_mostLiked,
          ),
          const SizedBox(height: 8),
          _buildUserChips(theme, summary.mostLikedUsers),
          const SizedBox(height: 20),
        ],

        // 热门类别
        if (summary.topCategories.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.category_rounded,
            context.l10n.userProfile_topCategories,
          ),
          const SizedBox(height: 8),
          ...summary.topCategories.map(
            (cat) => _buildSummaryCategoryItem(theme, cat),
          ),
          const SizedBox(height: 20),
        ],

        // 热门徽章
        if (summary.badges.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            Symbols.military_tech_rounded,
            context.l10n.userProfile_topBadges,
          ),
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
                  Icon(
                    Symbols.summarize_rounded,
                    size: 48,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.userProfile_noSummary,
                    style: TextStyle(color: Colors.grey[600]),
                  ),
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
              fontWeight: FontWeight.w600,
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
        onTap: () => _openTopic(topicId: topic.id, initialTitle: topic.title),
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

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
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
          padding: const EdgeInsets.all(12),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
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
          padding: const EdgeInsets.all(12),
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
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
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
            MaterialPageRoute(builder: (_) => BadgePage(badgeId: badge.id)),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              gradient: BadgeUIUtils.getBadgeGradient(context, badgeType),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.3)),
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
      return const UserActionListSkeleton();
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
              color: Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noReactions,
              style: TextStyle(color: Colors.grey[600]),
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
      child: M3eRefreshIndicator(
        onRefresh: () => _loadReactions(),
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
            return _buildReactionItem(reactions[index]);
          },
        ),
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
      return const UserActionListSkeleton();
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
              color: Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noBoosts,
              style: TextStyle(color: Colors.grey[600]),
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
      child: M3eRefreshIndicator(
        onRefresh: () => _loadBoosts(),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: boosts.length + 1,
          itemBuilder: (context, index) {
            if (index == boosts.length) {
              return PagedListFooter(
                hasMore: hasMore,
                isLoadingMore:
                    _boostsLoadMoreCoordinator.isRunning && isLoading,
                isLoadMoreFailed: _boostsLoadMoreFailed,
                onRetry: _loadMoreBoosts,
              );
            }
            return _buildBoostItem(boosts[index]);
          },
        ),
      ),
    );
  }

  /// 投票话题列表
  Widget _buildVotesList() {
    final topics = _votesCache;
    final isLoading = _votesLoading;
    final hasMore = _votesHasMore;

    // 优先检查 loading 状态
    if (isLoading && topics == null) {
      return const TopicListSkeleton();
    }

    // 空状态
    if (topics == null || topics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.how_to_vote_rounded,
              size: 48,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noVotes,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    final enableLongPress = ref.watch(
      preferencesProvider.select((p) => p.longPressPreview),
    );

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
      child: M3eRefreshIndicator(
        onRefresh: () => _loadVotes(),
        child: TopicCardPrewarmScope(
          topics: topics,
          child: ListView.builder(
          padding: const EdgeInsets.all(12),
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
            return buildTopicItem(
              context: context,
              topic: topic,
              isSelected: false,
              onTap: () => _openTopic(
                topicId: topic.id,
                initialTitle: topic.title,
                scrollToPostNumber: topic.lastReadPostNumber,
              ),
              enableLongPress: enableLongPress,
            );
          },
          ),
        ),
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
              color: Colors.grey[400],
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.userProfile_noSolved,
              style: TextStyle(color: Colors.grey[600]),
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
      child: M3eRefreshIndicator(
        onRefresh: () => _loadSolved(),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: posts.length + 1,
          itemBuilder: (context, index) {
            if (index == posts.length) {
              return PagedListFooter(
                hasMore: hasMore,
                isLoadingMore:
                    _solvedLoadMoreCoordinator.isRunning && isLoading,
                isLoadMoreFailed: _solvedLoadMoreFailed,
                onRetry: _loadMoreSolved,
              );
            }
            return _buildSolvedItem(posts[index]);
          },
        ),
      ),
    );
  }

  Widget _buildBoostItem(UserBoost boost) {
    final theme = Theme.of(context);
    final boostText = BoostContentParser.parse(boost.cooked).displayText;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openTopic(
          topicId: boost.topicId,
          scrollToPostNumber: boost.postNumber,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：Boost 内容和时间
              Row(
                children: [
                  Icon(
                    Symbols.rocket_launch_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      boostText.isNotEmpty
                          ? boostText
                          : context.l10n.userProfile_boosted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (boost.createdAt != null) ...[
                    const SizedBox(width: 8),
                    RelativeTimeText(
                      dateTime: boost.createdAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),

              // 话题标题
              if (boost.topicTitle != null && boost.topicTitle!.isNotEmpty)
                Text(
                  boost.topicTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),

              // 帖子内容摘要
              if (boost.excerpt != null && boost.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  boost.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
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

  Widget _buildSolvedItem(SolvedPost post) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openTopic(
          topicId: post.topicId,
          scrollToPostNumber: post.postNumber,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部：已解决标记和时间
              Row(
                children: [
                  Icon(
                    Symbols.check_circle_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.userProfile_solvedLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (post.createdAt != null)
                    RelativeTimeText(
                      dateTime: post.createdAt,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 话题标题
              if (post.topicTitle != null && post.topicTitle!.isNotEmpty)
                Text(
                  post.topicTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),

              // 被采纳回答摘要
              if (post.excerpt != null && post.excerpt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  post.excerpt!.replaceAll(RegExp(r'<[^>]*>'), ''),
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

  Widget _buildActionItem(UserAction action) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openTopic(
          topicId: action.topicId,
          scrollToPostNumber: action.postNumber,
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
                      fontWeight: FontWeight.w600,
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
                  fontWeight: FontWeight.w500,
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openTopic(
          topicId: reaction.topicId,
          scrollToPostNumber: reaction.postNumber,
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
                      errorBuilder: (_, _, _) =>
                          const Icon(Symbols.emoji_emotions_rounded, size: 20),
                    )
                  else
                    const Icon(Symbols.emoji_emotions_rounded, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    context.l10n.userProfile_reacted,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
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
              if (reaction.topicTitle != null &&
                  reaction.topicTitle!.isNotEmpty)
                Text(
                  reaction.topicTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
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
