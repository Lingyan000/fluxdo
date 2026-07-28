import 'dart:async';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../providers/discourse_providers.dart';
import '../providers/selected_topic_provider.dart';
import 'topics_screen.dart' show PaneContentWidget;
import '../providers/shortcut_provider.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../services/discourse_cache_manager.dart';
import 'webview_page.dart';
import 'login_page.dart';
import 'qr_login_display_page.dart';
import 'browsing_history_page.dart';
import 'bookmarks_page.dart';
import 'export_history_page.dart';
import 'my_browser_page.dart';
import 'my_topics_page.dart';
import 'my_badges_page.dart';
import 'user_profile_page.dart';
import 'trust_level_requirements_page.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/common/flair_badge.dart';
import '../widgets/common/smart_avatar.dart';
import '../providers/app_state_refresher.dart';
import 'metaverse_page.dart';
import 'package:ai_model_manager/ai_model_manager.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'drafts_page.dart';
import 'pending_posts_page.dart';
import 'private_messages_page.dart';
import 'invite_links_page.dart';
import '../providers/ldc_providers.dart';
import '../widgets/ldc_balance_card.dart';
import '../providers/cdk_providers.dart';
import '../widgets/cdk_balance_card.dart';
import '../widgets/profile_stats_card.dart';
import '../widgets/common/spotlight_overlay.dart';
import 'profile_stats_edit_page.dart';
import '../services/ldc_oauth_service.dart';
import '../services/cdk_oauth_service.dart';
import '../l10n/s.dart';
import '../navigation/nav_action_bus.dart';
import '../services/toast_service.dart';
import '../utils/dialog_utils.dart';
import '../utils/responsive.dart';
import '../services/emoji_handler.dart';
import '../services/log/log_writer.dart';
import '../providers/theme_provider.dart';
import '../widgets/layout/master_detail_layout.dart';

/// 个人页面
class ProfilePage extends ConsumerStatefulWidget {
  final bool isActive;
  const ProfilePage({super.key, this.isActive = false});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  late ScrollController _scrollController;
  late ScrollController _rightScrollController;
  bool _showTitle = false;
  bool _isRefreshing = false;

  // 余额卡片(CDK/LDC)是否已可渲染:仅在本页首次成为活跃 tab 后置 true。
  // 避免 IndexedStack 冷启动预构建本页时,balance card 的 watch 就触发
  // cdk/ldc user-info 请求(撞上 cdk 子域冷启动的 CF 挑战窗口)。
  bool _balanceEverActive = false;

  // 统计卡片引导
  static const String _guideKey = 'profile_stats_card_guide_shown';
  final GlobalKey _statsCardKey = GlobalKey();
  bool _guideShown = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _rightScrollController = ScrollController();
    // 启动即为活跃 tab(如默认进入本页)时允许立即渲染;否则等首次切入。
    _balanceEverActive = widget.isActive;
  }

  @override
  void didUpdateWidget(ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tab 切换时 isActive 变化
    if (widget.isActive && !oldWidget.isActive) {
      // 首次切入本页才渲染余额卡片(触发 cdk/ldc 请求),避免冷启动预构建即请求。
      // didUpdateWidget 后 framework 会自动 rebuild,无需 setState。
      _balanceEverActive = true;
      if (!_guideShown) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _tryShowStatsGuide();
        });
      }
    }
  }

  /// 刷新页面数据。
  ///
  /// [showAppBarIndicator] 为 false 时不点亮 AppBar 的刷新指示:
  /// 下拉/快捷键刷新自带圆片 spinner,再亮 AppBar 就是同屏双 loading;
  /// AppBar 指示只留给无下拉指示器的静默刷新(tab 切回等)。
  Future<void> _refreshData({bool showAppBarIndicator = true}) async {
    if (!mounted) return;
    if (showAppBarIndicator) setState(() => _isRefreshing = true);
    try {
      // LDC/CDK provider 现在只 watch currentUser.username，
      // refreshSilently 不会再连带触发它们 rebuild，需要显式刷新
      final prefs = ref.read(sharedPreferencesProvider);
      final ldcEnabled = prefs.getBool('ldc_enabled') ?? false;
      final cdkEnabled = prefs.getBool('cdk_enabled') ?? false;
      await Future.wait([
        ref.read(currentUserProvider.notifier).refreshSilently(force: true),
        ref.read(userSummaryProvider.notifier).refresh(),
        if (ldcEnabled) ref.read(ldcUserInfoProvider.notifier).refresh(),
        if (cdkEnabled) ref.read(cdkUserInfoProvider.notifier).refresh(),
      ]);
    } finally {
      if (mounted && showAppBarIndicator) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  @override
  void dispose() {
    SpotlightOverlay.dismiss();
    _scrollController.dispose();
    _rightScrollController.dispose();
    super.dispose();
  }

  /// 统计卡片引导：页面可见且卡片已渲染时触发（仅一次）
  Future<void> _tryShowStatsGuide() async {
    if (_guideShown) return;
    if (!widget.isActive) return;

    final renderObj = _statsCardKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderObj == null || !renderObj.hasSize) return;

    _guideShown = true;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_guideKey) == true) return;
    await prefs.setBool(_guideKey, true);

    if (!mounted) return;
    SpotlightOverlay.show(
      context,
      targetKey: _statsCardKey,
      message: S.current.profileStats_guideMessage,
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // 发布"距顶进度"给底栏图标（NavActionBus 的 progress provider）
    _publishProfileScrollProgress();

    // 双栏模式下头像始终可见，无需标题动画
    if (MasterDetailLayout.canShowBothPanesFor(context)) {
      if (_showTitle) setState(() => _showTitle = false);
      return;
    }

    // 当滚动超过一定距离（例如头像区域的高度）时显示标题
    // 头像(72) + padding(大概20)
    final show = _scrollController.offset > 80;
    if (show != _showTitle) {
      setState(() {
        _showTitle = show;
      });
    }
  }

  void _publishProfileScrollProgress() {
    final raw = _scrollController.offset;
    final progress = raw < 0 ? 0.0 : raw;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.profile));
    final atZero = progress == 0 && current != 0;
    final crossed = (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref.read(navScrollProgressProvider(NavEntryIds.profile).notifier).state =
        progress;
  }

  Future<void> _goToLogin() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    if (result == true && mounted) {
      final loading = LoadingDialog.show(
        context,
        message: context.l10n.profile_loadingData,
      );
      try {
        // 等加载弹框首帧结束后再刷新 provider，避免登录路由恢复时和
        // Overlay/TickerMode 的构建时机相撞。
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;

        AppStateRefresher.refreshAll(
          ProviderScope.containerOf(context, listen: false),
        );

        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(userSummaryProvider.future),
        ]).timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[ProfilePage] 登录后刷新失败/超时: $e');
        // 超时或错误时继续
      } finally {
        loading.hide();
      }
    }
  }
  
  Future<void> _logout() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.profile_confirmLogout),
        content: Text(context.l10n.profile_logoutContent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.common_cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.common_exit)),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      LoadingDialog.show(context, message: context.l10n.profile_loggingOut);

      // 记录主动退出日志
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'lifecycle',
        'event': 'logout_active',
        'message': '用户主动退出登录',
      });

      await ref.read(discourseServiceProvider).logout(callApi: true);
      if (mounted) {
        await AppStateRefresher.resetForLogout(
          ProviderScope.containerOf(context, listen: false),
        );
      }

      if (mounted) {
        LoadingDialog.hide(context);
      }
    }
  }

  Future<void> _reauthorizeLdc() async {
    final service = LdcOAuthService();
    if (!mounted) return;
    try {
      final result = await service.reauthorize(context);
      if (result && mounted) {
        ref.read(ldcUserInfoProvider.notifier).refresh();
        ToastService.showSuccess(S.current.profile_ldcReauthSuccess);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    }
  }

  Future<void> _reauthorizeCdk() async {
    final service = CdkOAuthService();
    if (!mounted) return;
    try {
      final result = await service.reauthorize(context);
      if (result && mounted) {
        ref.read(cdkUserInfoProvider.notifier).refresh();
        ToastService.showSuccess(S.current.profile_cdkReauthSuccess);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.metaverse_authFailed(e.toString()));
      }
    }
  }

  Future<void> _openProfileEdit() async {
    final username = ref.read(currentUserProvider).value?.username;
    if (username != null && username.isNotEmpty) {
      await WebViewPage.open(
        context, 
        'https://linux.do/u/$username/preferences/account',
        title: context.l10n.profile_editProfile,
        injectCss: '''
          .new-user-content-wrapper {
            position: fixed !important;
            top: 0 !important;
            left: 0 !important;
            width: 100% !important;
            height: 100% !important;
            z-index: 100 !important;
            background: var(--d-content-background, var(--secondary)) !important;
            overflow-y: auto !important;
            padding: 20px !important;
            box-sizing: border-box !important;
          }
          .d-header {
            display: none !important;
          }
        ''',
      );
      
      // 返回后静默刷新数据
      if (mounted) {
        ref.read(currentUserProvider.notifier).refreshSilently().ignore();
        ref.read(userSummaryProvider.notifier).refresh();
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {

    final theme = Theme.of(context);
    final userState = ref.watch(currentUserProvider);
    final isLoggedIn = userState.value != null;
    final user = userState.value;
    final displayName = user?.name ?? user?.username ?? '';

    final isOffline = userState.hasError && userState.hasValue && userState.value != null;
    final showWideLayout = MasterDetailLayout.canShowBothPanesFor(context);

    // 监听底栏派发的快捷动作（仅活跃 tab 响应）
    ref.listen(navActionBusProvider, (_, event) {
      if (event == null) return;
      if (event.targetId != NavEntryIds.profile) return;
      if (!widget.isActive) return;
      switch (event.action) {
        case NavAction.scrollToTop:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          break;
        case NavAction.refresh:
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
          _refreshData();
          ref.resetNavScrollProgress(NavEntryIds.profile);
          break;
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: !showWideLayout && _showTitle && displayName.isNotEmpty
            ? GestureDetector(
                onTap: () {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SmartAvatar(
                      imageUrl: user?.getAvatarUrl(),
                      radius: 14,
                      fallbackText: displayName,
                    ),
                    const SizedBox(width: 8),
                    Text(displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  ],
                ),
              )
            : null,
        centerTitle: false,
        actions: isLoggedIn ? [
          // 状态指示（固定占位，避免后方图标闪烁）
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _isRefreshing
                ? const SizedBox(
                    key: ValueKey('refreshing'),
                    width: 48,
                    height: 48,
                    child: Center(
                      child: LoadingSpinner(size: 18),
                    ),
                  )
                : isOffline
                    ? SizedBox(
                        key: const ValueKey('offline'),
                        width: 48,
                        height: 48,
                        child: Icon(Symbols.cloud_off_rounded, color: theme.colorScheme.outline),
                      )
                    : const SizedBox(key: ValueKey('idle'), width: 0),
          ),
          IconButton(
            icon: const Icon(Symbols.manage_accounts_rounded),
            tooltip: context.l10n.profile_editProfile,
            onPressed: _openProfileEdit,
          ),
          // 侧栏模式下通知角标已在侧栏头像上显示
          if (!Responsive.showNavigationRail(context))
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: NotificationIconButton(),
            ),
        ] : null,
      ),
      // 宽屏才提供平行视界栈：窄屏没有右栏可承载，openDrafts/openSettings
      // 必须走全屏 push（有 scope 却没人渲染 = 点了没反应）。
      body: showWideLayout
          ? EmbeddedStackScope(
              stackProvider: selectedProfilePaneProvider,
              child: _buildWideBody(theme),
            )
          : _buildMobileBody(theme),
    );
  }

  /// 手机端：保持原有单列布局
  Widget _buildMobileBody(ThemeData theme) {
    final userState = ref.watch(currentUserProvider);
    final isLoggedIn = userState.value != null;
    final user = userState.value;
    final isLoadingInitial = userState.isLoading && !userState.hasValue;
    final hasError = userState.hasError && !userState.hasValue;
    final errorMessage = userState.error?.toString() ?? '';

    return DesktopRefreshIndicator(
      refreshNotifier: masterRefreshNotifier,
      shouldRefresh: () => widget.isActive,
      onRefresh: () => _refreshData(showAppBarIndicator: false),
      child: ListView(
        controller: _scrollController,
        // 底部让出 extendBody 注入的底栏高度
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: 12 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const _ProfileHeader(),
          const SizedBox(height: 24),

          if (isLoadingInitial)
            const Center(child: Padding(
              padding: EdgeInsets.all(64),
              child: LoadingSpinner(),
            ))
          else if (hasError)
            _buildError(theme, errorMessage)
          else if (isLoggedIn)
            _buildStatsCardWithGuide(),

          _buildBalanceCards(),

          if (isLoggedIn) ...[
            _buildContentCard(theme),
            const SizedBox(height: 20),
            _buildCommunityCard(
              theme,
              canAccessInviteLinks: (user?.trustLevel ?? 0) >= 3,
            ),
            const SizedBox(height: 20),
          ],

          _buildSystemAndToolsCard(theme),
          const SizedBox(height: 32),
          _buildAuthButton(theme, isLoggedIn),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  /// 平板/桌面端：左右双栏布局
  Widget _buildWideBody(ThemeData theme) {
    // 右半边：栈为空时是原来的卡片列表，压了内容（草稿/设置）就顶替掉。
    final selected = ref.watch(selectedProfilePaneProvider);
    final entry = selected.topEntry;
    final notifier = ref.read(selectedProfilePaneProvider.notifier);
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: _buildLeftPanel(theme),
        ),
        VerticalDivider(width: 1, thickness: 0.5, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
        Expanded(
          child: entry == null
              ? _buildRightPanel(theme)
              : PaneContentWidget(
                  key: ValueKey(
                    'profile_pane_${entry.kind}_'
                    '${entry.instanceId ?? entry.username ?? entry.topicId}',
                  ),
                  entry: entry,
                  stackProvider: selectedProfilePaneProvider,
                  parentActive: widget.isActive,
                  onBack: () =>
                      selected.isStacked ? notifier.pop() : notifier.clear(),
                ),
        ),
      ],
    );
  }

  /// 左面板：资料卡 + 统计 + 余额卡片 + 登录/退出按钮固定底部
  Widget _buildLeftPanel(ThemeData theme) {
    final userState = ref.watch(currentUserProvider);
    final isLoggedIn = userState.value != null;
    final isLoadingInitial = userState.isLoading && !userState.hasValue;
    final hasError = userState.hasError && !userState.hasValue;
    final errorMessage = userState.error?.toString() ?? '';

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              children: [
                const _ProfileHeader(),
                const SizedBox(height: 24),

                if (isLoadingInitial)
                  const Center(child: Padding(
                    padding: EdgeInsets.all(64),
                    child: LoadingSpinner(),
                  ))
                else if (hasError)
                  _buildError(theme, errorMessage)
                else if (isLoggedIn)
                  _buildStatsCardWithGuide(),

                _buildBalanceCards(),

                if (isLoggedIn) ...[
                  _buildContentCard(theme),
                  const SizedBox(height: 24),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: _buildAuthButton(theme, isLoggedIn),
        ),
      ],
    );
  }

  /// 右面板：功能菜单卡片
  Widget _buildRightPanel(ThemeData theme) {
    final userState = ref.watch(currentUserProvider);
    final isLoggedIn = userState.value != null;
    final user = userState.value;

    return DesktopRefreshIndicator(
      refreshNotifier: masterRefreshNotifier,
      shouldRefresh: () => widget.isActive,
      onRefresh: () => _refreshData(showAppBarIndicator: false),
      child: ListView(
        controller: _rightScrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          if (isLoggedIn) ...[
            _buildCommunityCard(
              theme,
              canAccessInviteLinks: (user?.trustLevel ?? 0) >= 3,
            ),
            const SizedBox(height: 20),
          ],
          _buildSystemAndToolsCard(theme),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  /// LDC/CDK 余额卡片（共用组件）
  Widget _buildBalanceCards() {
    // 仅本页首次成为活跃 tab 后才渲染余额卡片;未激活时返回空,不建 Consumer、
    // 不 watch provider,从而不触发 cdk/ldc user-info 请求。
    if (!_balanceEverActive) return const SizedBox.shrink();
    return Consumer(
      builder: (context, ref, _) {
        final prefs = ref.watch(sharedPreferencesProvider);
        final ldcEnabled = prefs.getBool('ldc_enabled') ?? false;
        final cdkEnabled = prefs.getBool('cdk_enabled') ?? false;

        if (!ldcEnabled && !cdkEnabled) return const SizedBox.shrink();

        return Column(
          children: [
            SegmentedCardGroup(
              children: [
                if (ldcEnabled)
                  LdcBalanceCard(
                    inline: true,
                    onReauthorize: () => _reauthorizeLdc(),
                  ),
                if (cdkEnabled)
                  CdkBalanceCard(
                    inline: true,
                    onReauthorize: () => _reauthorizeCdk(),
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
  
  Widget _buildError(ThemeData theme, String error) {
    return Card(
      color: theme.colorScheme.errorContainer.withValues(alpha:0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Symbols.error_rounded, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text('${context.l10n.common_loadFailed}: $error', style: theme.textTheme.bodySmall)),
            TextButton(
              onPressed: () => ref.invalidate(currentUserProvider),
              child: Text(context.l10n.common_retry)
            ),
          ],
        ),
      ),
    );
  }
  
  /// 统计卡片 + 引导触发
  Widget _buildStatsCardWithGuide() {
    return Column(
      children: [
        ProfileStatsCard(
          statsCardKey: _statsCardKey,
          onEdit: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ProfileStatsEditPage()),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  void _openDrafts() {
    // 草稿页是独立的双栏页(宽屏自带"左列表右话题"),所有入口统一
    // 全屏打开,不再往「我的」页右栏塞草稿层。
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DraftsPage()),
    );
  }

  Widget _buildContentCard(ThemeData theme) {
    final actions = [
      (
        icon: Symbols.article_rounded,
        iconColor: Colors.blue,
        title: context.l10n.profile_myTopics,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const MyTopicsPage()),
        ),
      ),
      (
        icon: Symbols.bookmark_rounded,
        iconColor: Colors.orange,
        title: context.l10n.profile_myBookmarks,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BookmarksPage()),
        ),
      ),
      (
        icon: Symbols.drafts_rounded,
        iconColor: Colors.teal,
        title: context.l10n.profile_myDrafts,
        onTap: _openDrafts,
      ),
      (
        icon: Symbols.history_rounded,
        iconColor: Colors.purple,
        title: context.l10n.profile_browsingHistory,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BrowsingHistoryPage()),
        ),
      ),
    ];

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final columns = constraints.maxWidth < 220
                ? 1
                : constraints.maxWidth < 300
                    ? 2
                    : 4;
            final itemWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final action in actions)
                  SizedBox(
                    width: itemWidth,
                    child: _buildCompactActionItem(
                      theme,
                      action.icon,
                      action.iconColor,
                      action.title,
                      action.onTap,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCompactActionItem(ThemeData theme, IconData icon, Color iconColor, String title, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommunityCard(ThemeData theme, {required bool canAccessInviteLinks}) {
    final username = ref.read(currentUserProvider).value?.username;
    return SegmentedCardGroup(
      children: [
        _buildOptionTile(
          icon: Symbols.qr_code_rounded,
          iconColor: Colors.teal,
          title: context.l10n.login_qrShowCode,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QrLoginDisplayPage(username: username),
            ),
          ),
        ),
        _buildOptionTile(
          icon: Symbols.mail_rounded,
          iconColor: Colors.indigo,
          title: context.l10n.profile_privateMessages,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivateMessagesPage())),
        ),
        _buildOptionTile(
          icon: Symbols.pending_actions_rounded,
          iconColor: Colors.amber,
          title: context.l10n.review_myPending,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PendingPostsPage())),
        ),
        _buildOptionTile(
          icon: Symbols.military_tech_rounded,
          iconColor: Colors.amber[700]!,
          title: context.l10n.profile_myBadges,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBadgesPage()))
        ),
        _buildOptionTile(
          icon: Symbols.verified_user_rounded,
          iconColor: Colors.green,
          title: context.l10n.profile_trustRequirements,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrustLevelRequirementsPage()))
        ),
        if (canAccessInviteLinks)
          _buildOptionTile(
            icon: Symbols.link_rounded,
            iconColor: Colors.cyan,
            title: context.l10n.profile_inviteLinks,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const InviteLinksPage()),
            ),
          ),
        _buildOptionTile(
          icon: Symbols.history_edu_rounded,
          iconColor: Colors.pink,
          title: context.l10n.exportHistory_title,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ExportHistoryPage()),
          ),
        ),
        _buildOptionTile(
          icon: Symbols.explore_rounded,
          iconColor: Colors.deepOrange,
          title: context.l10n.profile_metaverse,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MetaversePage()))
        ),
      ],
    );
  }

  Widget _buildSystemAndToolsCard(ThemeData theme) {
    return SegmentedCardGroup(
      children: [
        _buildOptionTile(
          icon: Symbols.language_rounded,
          iconColor: Colors.blue,
          title: context.l10n.profile_myBrowser,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBrowserPage()))
        ),
        _buildOptionTile(
          icon: Symbols.smart_toy_rounded,
          iconColor: Colors.cyan,
          title: context.l10n.profile_aiModelService,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AiProvidersPage(
            onOpenSession: (ctx, topicId, sessionId) {
              Navigator.push(ctx, MaterialPageRoute(
                builder: (_) => TopicDetailPage(
                  topicId: topicId,
                  autoOpenAiChat: true,
                  initialSessionId: sessionId,
                ),
              ));
            },
          ))),
        ),
        _buildOptionTile(
          icon: Symbols.settings_rounded,
          iconColor: Colors.blueGrey,
          title: context.l10n.profile_settings,
          onTap: () => EmbeddedStackScope.openSettings(context),
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
            // iOS 风格的图标容器保留，因为这不违和且好看
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: finalIconColor.withValues(alpha:0.1),
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
                  fontWeight: FontWeight.w500
                )
              )
            ),
            Icon(
              Symbols.chevron_right_rounded,
              color: theme.colorScheme.outline.withValues(alpha:0.4),
              size: 20
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildAuthButton(ThemeData theme, bool isLoggedIn) {
    if (isLoggedIn) {
      return Center(
        child: TextButton.icon(
          onPressed: _logout,
          icon: Icon(Symbols.logout_rounded, size: 18, color: theme.colorScheme.error.withValues(alpha:0.8)),
          label: Text(context.l10n.profile_logoutCurrentAccount, style: TextStyle(color: theme.colorScheme.error.withValues(alpha:0.8), fontWeight: FontWeight.w500)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            backgroundColor: theme.colorScheme.errorContainer.withValues(alpha:0.1),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
      );
    } else {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FilledButton.icon(
          onPressed: _goToLogin,
          icon: const Icon(Symbols.login_rounded, size: 20),
          label: Text(context.l10n.profile_loginLinuxDo, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );
    }
  }
}

class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(currentUserProvider.select((value) => value.value?.id));
    final username = ref.watch(currentUserProvider.select((value) => value.value?.username));
    final isLoggedIn = ref.watch(currentUserProvider.select((value) => value.value != null));
    final canNavigate = username != null && username.isNotEmpty;

    return GestureDetector(
      onTap: canNavigate
          ? () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => UserProfilePage(username: username)),
              );
            }
          : null,
      child: Container(
        color: Colors.transparent,
        child: Row(
          children: [
            _ProfileAvatarSection(userId: userId, isLoggedIn: isLoggedIn),
            const SizedBox(width: 20),
            const Expanded(child: _ProfileInfoSection()),
            if (isLoggedIn)
              CircleAvatar(
                radius: 16,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Symbols.arrow_forward_ios_rounded,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfileAvatarSection extends ConsumerWidget {
  final int? userId;
  final bool isLoggedIn;

  const _ProfileAvatarSection({
    required this.userId,
    required this.isLoggedIn,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatarUrl = ref.watch(
      currentUserProvider.select((value) => value.value?.getAvatarUrl() ?? ''),
    );
    final flairUrl = ref.watch(currentUserProvider.select((value) => value.value?.flairUrl));
    final flairName = ref.watch(currentUserProvider.select((value) => value.value?.flairName));
    final flairBgColor = ref.watch(currentUserProvider.select((value) => value.value?.flairBgColor));
    final flairColor = ref.watch(currentUserProvider.select((value) => value.value?.flairColor));

    return _ProfileAvatar(
      key: ValueKey('profile-avatar-$userId'),
      userId: userId,
      avatarUrl: avatarUrl,
      isLoggedIn: isLoggedIn,
      flairUrl: flairUrl,
      flairName: flairName,
      flairBgColor: flairBgColor,
      flairColor: flairColor,
    );
  }
}

class _ProfileInfoSection extends ConsumerWidget {
  const _ProfileInfoSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = ref.watch(currentUserProvider.select((value) => value.value?.name));
    final username = ref.watch(currentUserProvider.select((value) => value.value?.username));
    final trustLevel = ref.watch(currentUserProvider.select((value) => value.value?.trustLevel));
    final status = ref.watch(currentUserProvider.select((value) => value.value?.status));
    final isLoggedIn = ref.watch(currentUserProvider.select((value) => value.value != null));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name ?? username ?? (isLoggedIn ? context.l10n.common_loading : context.l10n.profile_notLoggedIn),
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 22,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (isLoggedIn) ...[
          const SizedBox(height: 4),
          Text(
            '@${username ?? ''}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _getTrustLevelLabel(trustLevel ?? 0),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (status != null) _buildStatusChip(status, theme),
            ],
          ),
        ] else ...[
          const SizedBox(height: 4),
          Text(
            context.l10n.profile_loginForMore,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// 独立的头像组件，使用 AutomaticKeepAliveClientMixin 避免重建
class _ProfileAvatar extends StatefulWidget {
  final int? userId;
  final String avatarUrl;
  final bool isLoggedIn;
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;

  const _ProfileAvatar({
    super.key,
    required this.userId,
    required this.avatarUrl,
    required this.isLoggedIn,
    this.flairUrl,
    this.flairName,
    this.flairBgColor,
    this.flairColor,
  });

  @override
  State<_ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<_ProfileAvatar> with AutomaticKeepAliveClientMixin {
  Widget? _cachedAvatarWithFlair;
  String _cachedSignature = '';

  @override
  bool get wantKeepAlive => true;

  String _buildCacheSignature() {
    return '${widget.avatarUrl}_${widget.flairUrl}_${widget.flairName}_${widget.flairBgColor}_${widget.flairColor}';
  }

  @override
  void didUpdateWidget(_ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newSignature = _buildCacheSignature();
    if (newSignature != _cachedSignature) {
      _cachedAvatarWithFlair = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须调用以支持 AutomaticKeepAliveClientMixin

    final signature = _buildCacheSignature();
    if (_cachedAvatarWithFlair != null && signature == _cachedSignature) {
      return _cachedAvatarWithFlair!;
    }
    _cachedSignature = signature;

    final theme = Theme.of(context);

    _cachedAvatarWithFlair = AvatarWithFlair(
      key: ValueKey('profile-avatar-flair-${widget.userId}-${widget.flairUrl}'),
      flairSize: 24,
      flairRight: -2,
      flairBottom: -2,
      flairUrl: widget.flairUrl,
      flairName: widget.flairName,
      flairBgColor: widget.flairBgColor,
      flairColor: widget.flairColor,
      avatar: SmartAvatar(
        imageUrl: widget.avatarUrl.isNotEmpty ? widget.avatarUrl : null,
        radius: 36,
        fallbackText: widget.isLoggedIn ? null : '',
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: theme.colorScheme.surfaceContainerHighest,
          width: 1,
        ),
      ),
    );

    return _cachedAvatarWithFlair!;
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
      return 'L$level';
  }
}

Widget _buildStatusEmoji(UserStatus status) {
  final emoji = status.emoji;
  if (emoji == null || emoji.isEmpty) return const SizedBox.shrink();

  final isEmojiName =
      emoji.contains(RegExp(r'[a-zA-Z0-9_]')) && !emoji.contains(RegExp(r'[^\x00-\x7F]'));

  if (isEmojiName) {
    final cleanName = emoji.replaceAll(':', '');
    final emojiUrl = EmojiHandler().getEmojiUrl(cleanName);

    return Image(
      image: emojiImageProvider(emojiUrl),
      width: 14,
      height: 14,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }

  return Text(
    emoji,
    style: const TextStyle(fontSize: 12, height: 1.2),
  );
}

Widget _buildStatusChip(UserStatus status, ThemeData theme) {
  final emoji = status.emoji;
  final description = status.description;

  if ((emoji == null || emoji.isEmpty) && (description == null || description.isEmpty)) {
    return const SizedBox.shrink();
  }

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha:0.5)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (emoji != null && emoji.isNotEmpty) ...[
          _buildStatusEmoji(status),
          if (description != null && description.isNotEmpty) const SizedBox(width: 4),
        ],
        if (description != null && description.isNotEmpty)
          Flexible(
            child: Text(
              description,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ),
  );
}
