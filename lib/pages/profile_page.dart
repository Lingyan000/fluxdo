import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../providers/discourse_providers.dart';
import '../providers/shortcut_provider.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../services/discourse_cache_manager.dart';
import 'webview_page.dart';
import 'webview_login_page.dart';
import 'browsing_history_page.dart';
import 'bookmarks_page.dart';
import 'my_browser_page.dart';
import 'my_topics_page.dart';
import 'my_badges_page.dart';
import 'user_profile_page.dart';
import 'trust_level_requirements_page.dart';
import 'settings_page.dart';
import '../widgets/common/loading_spinner.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/common/flair_badge.dart';
import '../widgets/common/smart_avatar.dart';
import '../providers/app_state_refresher.dart';
import 'metaverse_page.dart';
import 'package:ai_model_manager/ai_model_manager.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'drafts_page.dart';
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
  }

  @override
  void didUpdateWidget(ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tab 切换时 isActive 变化
    if (widget.isActive && !oldWidget.isActive && !_guideShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryShowStatsGuide();
      });
    }
  }

  /// 下拉刷新
  /// 注意：LDC/CDK provider 的 build() 中 ref.watch(currentUserProvider) 会在
  /// currentUser 刷新后自动重建，无需显式调用 refresh()，否则会触发两次 loading
  Future<void> _refreshData() async {
    if (!mounted) return;
    setState(() => _isRefreshing = true);
    try {
      await Future.wait([
        ref.read(currentUserProvider.notifier).refreshSilently(force: true),
        ref.read(userSummaryProvider.notifier).refresh(),
      ]);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
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

  Future<void> _goToLogin() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebViewLoginPage()),
    );
    if (result == true && mounted) {
      LoadingDialog.show(context, message: context.l10n.profile_loadingData);

      AppStateRefresher.refreshAll(ref);

      try {
        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(userSummaryProvider.future),
        ]).timeout(const Duration(seconds: 10));
      } catch (_) {
        // 超时或错误时继续
      }

      if (mounted) {
        LoadingDialog.hide(context);
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
        await AppStateRefresher.resetForLogout(ref);
      }

      if (mounted) {
        LoadingDialog.hide(context);
      }
    }
  }

  Future<void> _reauthorizeLdc() async {
    final service = LdcOAuthService();
    try {
      await service.logout();
    } catch (_) {
      // 忽略登出错误
    }
    if (!mounted) return;
    try {
      final result = await service.authorize(context);
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
    try {
      await service.logout();
    } catch (_) {
      // 忽略登出错误
    }
    if (!mounted) return;
    try {
      final result = await service.authorize(context);
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
                    Text(displayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : isOffline
                    ? SizedBox(
                        key: const ValueKey('offline'),
                        width: 48,
                        height: 48,
                        child: Icon(Icons.cloud_off_rounded, color: theme.colorScheme.outline),
                      )
                    : const SizedBox(key: ValueKey('idle'), width: 0),
          ),
          IconButton(
            icon: const Icon(Icons.manage_accounts_rounded),
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
      body: showWideLayout ? _buildWideBody(theme) : _buildMobileBody(theme),
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
      onRefresh: _refreshData,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: _buildLeftPanel(theme),
        ),
        VerticalDivider(width: 1, thickness: 0.5, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
        Expanded(
          child: _buildRightPanel(theme),
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
      onRefresh: _refreshData,
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
    return Consumer(
      builder: (context, ref, _) {
        final prefs = ref.watch(sharedPreferencesProvider);
        final ldcEnabled = prefs.getBool('ldc_enabled') ?? false;
        final cdkEnabled = prefs.getBool('cdk_enabled') ?? false;

        if (!ldcEnabled && !cdkEnabled) return const SizedBox.shrink();

        return Column(
          children: [
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (ldcEnabled)
                    LdcBalanceCard(
                      inline: true,
                      onReauthorize: () => _reauthorizeLdc(),
                      showDivider: cdkEnabled,
                    ),
                  if (cdkEnabled)
                    CdkBalanceCard(
                      inline: true,
                      onReauthorize: () => _reauthorizeCdk(),
                    ),
                ],
              ),
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
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
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

  Widget _buildContentCard(ThemeData theme) {
    final actions = [
      (
        icon: Icons.article_rounded,
        iconColor: Colors.blue,
        title: context.l10n.profile_myTopics,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const MyTopicsPage()),
        ),
      ),
      (
        icon: Icons.bookmark_rounded,
        iconColor: Colors.orange,
        title: context.l10n.profile_myBookmarks,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BookmarksPage()),
        ),
      ),
      (
        icon: Icons.drafts_rounded,
        iconColor: Colors.teal,
        title: context.l10n.profile_myDrafts,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const DraftsPage()),
        ),
      ),
      (
        icon: Icons.history_rounded,
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
        borderRadius: BorderRadius.circular(16),
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
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildOptionTile(
            icon: Icons.mail_rounded,
            iconColor: Colors.indigo,
            title: context.l10n.profile_privateMessages,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivateMessagesPage())),
          ),
          _buildOptionTile(
            icon: Icons.military_tech_rounded,
            iconColor: Colors.amber[700]!,
            title: context.l10n.profile_myBadges,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBadgesPage()))
          ),
          _buildOptionTile(
            icon: Icons.verified_user_rounded, 
            iconColor: Colors.green,
            title: context.l10n.profile_trustRequirements,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrustLevelRequirementsPage()))
          ),
          if (canAccessInviteLinks)
            _buildOptionTile(
              icon: Icons.link_rounded,
              iconColor: Colors.cyan,
              title: context.l10n.profile_inviteLinks,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const InviteLinksPage()),
              ),
            ),
          _buildOptionTile(
            icon: Icons.explore_rounded,
            iconColor: Colors.deepOrange,
            title: context.l10n.profile_metaverse,
            showDivider: false,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MetaversePage()))
          ),
        ],
      ),
    );
  }

  Widget _buildSystemAndToolsCard(ThemeData theme) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildOptionTile(
            icon: Icons.language_rounded,
            iconColor: Colors.blue,
            title: context.l10n.profile_myBrowser,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBrowserPage()))
          ),
          _buildOptionTile(
            icon: Icons.smart_toy_rounded,
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
            icon: Icons.settings_rounded,
            iconColor: Colors.blueGrey,
            title: context.l10n.profile_settings,
            showDivider: false,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
    );
  }
  
  Widget _buildOptionTile({
    required IconData icon, 
    Color? iconColor,
    required String title, 
    required VoidCallback onTap,
    bool showDivider = true,
  }) {
    final theme = Theme.of(context);
    final finalIconColor = iconColor ?? theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Padding(
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
                    Icons.chevron_right_rounded, 
                    color: theme.colorScheme.outline.withValues(alpha:0.4), 
                    size: 20
                  ),
                ],
              ),
            ),
            if (showDivider)
              Padding(
                padding: const EdgeInsets.only(left: 60), // 对齐文字
                child: Divider(
                  height: 1, 
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withValues(alpha:0.2)
                ),
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
          icon: Icon(Icons.logout_rounded, size: 18, color: theme.colorScheme.error.withValues(alpha:0.8)),
          label: Text(context.l10n.profile_logoutCurrentAccount, style: TextStyle(color: theme.colorScheme.error.withValues(alpha:0.8), fontWeight: FontWeight.w600)),
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
          icon: const Icon(Icons.login_rounded, size: 20),
          label: Text(context.l10n.profile_loginLinuxDo, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
                  Icons.arrow_forward_ios_rounded,
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
            fontWeight: FontWeight.bold,
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
                    fontWeight: FontWeight.w600,
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
