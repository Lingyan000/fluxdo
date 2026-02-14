import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants.dart';
import '../models/user.dart';
import '../providers/discourse_providers.dart';
import 'webview_page.dart';
import 'webview_login_page.dart';
import 'appearance_page.dart';
import 'browsing_history_page.dart';
import 'bookmarks_page.dart';
import 'my_topics_page.dart';
import 'my_badges_page.dart';
import 'user_profile_page.dart';
import 'trust_level_requirements_page.dart';
import 'about_page.dart';
import 'network_settings_page/network_settings_page.dart';
import 'preferences_page.dart';
import '../widgets/common/loading_spinner.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/common/flair_badge.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/common/user_status_helpers.dart';
import '../providers/app_state_refresher.dart';
import 'metaverse_page.dart';
import 'drafts_page.dart';
import '../widgets/ldc_balance_card.dart';
import '../providers/ldc_providers.dart';
import '../utils/number_utils.dart';

/// 个人页面
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  late ScrollController _scrollController;
  bool _showTitle = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    
    // 进入页面后静默刷新用户数据（不触发 loading 状态）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final current = ref.read(currentUserProvider).value;
        if (current != null) {
          // 使用 refresh 在后台更新数据，不会触发 loading 状态，避免 UI 闪烁
          // 忽略返回值，因为我们只是触发后台刷新
          ref.read(currentUserProvider.notifier).refreshSilently().ignore();
          ref.refresh(userSummaryProvider.future).ignore();
        }
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    
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
      LoadingDialog.show(context, message: '加载数据...');

      // 刷新所有状态
      AppStateRefresher.refreshAll(ref);

      // 等待关键数据加载完成
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认退出'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      LoadingDialog.show(context, message: '正在退出...');

      await ref.read(discourseServiceProvider).logout(callApi: true);
      if (mounted) {
        await AppStateRefresher.resetForLogout(ref);
      }

      if (mounted) {
        LoadingDialog.hide(context);
      }
    }
  }

  Future<void> _openProfileEdit() async {
    final username = ref.read(currentUserProvider).value?.username;
    if (username != null && username.isNotEmpty) {
      await WebViewPage.open(
        context, 
        '${AppConstants.baseUrl}/u/$username/preferences/account',
        title: '编辑资料',
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
        ref.refresh(userSummaryProvider.future).ignore();
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
    
    final isLoadingInitial = userState.isLoading && !userState.hasValue;
    final hasError = userState.hasError && !userState.hasValue;
    final errorMessage = userState.error?.toString() ?? '';

    return Scaffold(
      appBar: AppBar(
        title: _showTitle && displayName.isNotEmpty 
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
          IconButton(
            icon: const Icon(Icons.manage_accounts_rounded),
            tooltip: '编辑资料',
            onPressed: _openProfileEdit,
          ),
          const Padding(
            padding: EdgeInsets.only(right: 8.0),
            child: NotificationIconButton(),
          )
        ] : null,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final current = ref.read(currentUserProvider).value;
          if (current == null) return;
          await ref.read(currentUserProvider.notifier).refreshSilently();
          ref.invalidate(userSummaryProvider);
          final service = ref.read(discourseServiceProvider);
          final user = ref.read(currentUserProvider).value;
          if (user != null) {
            await service.getUserSummary(user.username, forceRefresh: true);
          }
        },
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
            else
              Consumer(
                builder: (context, ref, _) {
                  final summary = ref.watch(userSummaryProvider.select((value) => value.value));
                  final loggedIn = ref.watch(
                    currentUserProvider.select((value) => value.value != null),
                  );
                  if (!loggedIn || summary == null) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    children: [
                      _buildStatsRow(theme, summary),
                      const SizedBox(height: 24),
                    ],
                  );
                },
              ),

            Consumer(
              builder: (context, ref, _) {
                final ldcUserInfo = ref.watch(ldcUserInfoProvider).value;
                if (ldcUserInfo == null) return const SizedBox.shrink();
                return Column(
                  children: const [
                    LdcBalanceCard(compact: true),
                    SizedBox(height: 24),
                  ],
                );
              },
            ),

            if (isLoggedIn) ...[
              _buildOptionsCard(theme),
              const SizedBox(height: 20),
            ],
            _buildAboutCard(theme),
            const SizedBox(height: 32),
            _buildAuthButton(theme, isLoggedIn),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
  
  Widget _buildError(ThemeData theme, String error) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.errorContainer.withValues(alpha:0.3),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.error.withValues(alpha:0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text('加载失败: $error', style: theme.textTheme.bodySmall)),
            TextButton(
              onPressed: () => ref.invalidate(currentUserProvider), 
              child: const Text('重试')
            ),
          ],
        ),
      ),
    );
  }
  
  /// 社区表现 - 使用 Card 保持一致性
  Widget _buildStatsRow(ThemeData theme, UserSummary summary) {
    return Card(
      elevation: 0,
       // 使用 surfaceContainerLow 与其他列表卡片区分或一致，这里选择稍微突出一点
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha:0.2)),
      ),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.daysVisited), '访问天数', summary.daysVisited),
            _buildVerticalDivider(theme),
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.postsReadCount), '阅读帖子', summary.postsReadCount),
            _buildVerticalDivider(theme),
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.likesReceived), '获得点赞', summary.likesReceived),
            _buildVerticalDivider(theme),
            _buildCompactStatItem(theme, NumberUtils.formatCount(summary.postCount), '发表回复', summary.postCount),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalDivider(ThemeData theme) {
    return Container(
      height: 20,
      width: 1,
      color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
    );
  }

  Widget _buildCompactStatItem(ThemeData theme, String value, String label, int rawValue) {
    return Tooltip(
      message: '$rawValue',
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            )
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            )
          ),
        ],
      ),
    );
  }
  
  Widget _buildOptionsCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha:0.2)),
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildOptionTile(
            icon: Icons.bookmark_rounded,
            iconColor: Colors.orange,
            title: '我的书签',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BookmarksPage()))
          ),
          _buildOptionTile(
            icon: Icons.drafts_rounded,
            iconColor: Colors.teal,
            title: '我的草稿',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DraftsPage()))
          ),
          _buildOptionTile(
            icon: Icons.article_rounded, 
            iconColor: Colors.blue,
            title: '我的话题', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyTopicsPage()))
          ),
          _buildOptionTile(
            icon: Icons.military_tech_rounded, 
            iconColor: Colors.amber[700]!,
            title: '我的徽章', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBadgesPage()))
          ),
          _buildOptionTile(
            icon: Icons.verified_user_rounded, 
            iconColor: Colors.green,
            title: '信任要求', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrustLevelRequirementsPage()))
          ),
          _buildOptionTile(
            icon: Icons.history_rounded,
            iconColor: Colors.purple,
            title: '浏览历史',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BrowsingHistoryPage()))
          ),
          _buildOptionTile(
            icon: Icons.explore_rounded,
            iconColor: Colors.deepOrange,
            title: '元宇宙',
            showDivider: false,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MetaversePage()))
          ),
        ],
      ),
    );
  }
  
  Widget _buildAboutCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha:0.2)),
      ),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _buildOptionTile(
            icon: Icons.color_lens_rounded, 
            iconColor: Colors.teal,
            title: '外观设置', 
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearancePage()))
          ),
          _buildOptionTile(
            icon: Icons.network_check_rounded,
            iconColor: Colors.blueGrey,
            title: '网络设置',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NetworkSettingsPage())),
          ),
          _buildOptionTile(
            icon: Icons.tune_rounded,
            iconColor: Colors.deepPurple,
            title: '偏好设置',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PreferencesPage())),
          ),
          _buildOptionTile(
            icon: Icons.info_rounded,
            iconColor: Colors.indigo,
            title: '关于 FluxDO',
            showDivider: false,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage())),
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
          label: Text('退出当前账号', style: TextStyle(color: theme.colorScheme.error.withValues(alpha:0.8), fontWeight: FontWeight.w600)),
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
          label: const Text('登录 Linux.do', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
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
          name ?? username ?? (isLoggedIn ? '加载中...' : '未登录'),
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
                  getTrustLevelLabel(trustLevel ?? 0),
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
            '登录后体验更多功能',
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
          buildStatusEmoji(status),
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
