import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../models/badge.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/url_helper.dart';
import '../widgets/badge/my_badges_skeleton.dart';
import '../widgets/common/error_view.dart';
import '../utils/font_awesome_helper.dart';
import '../widgets/badge/badge_ui_utils.dart';
import 'badge_page.dart';
import '../l10n/s.dart';
import '../widgets/layout/auto_restore_master_detail_route.dart';
import '../widgets/layout/master_detail_layout.dart';

/// 我的徽章页面
class MyBadgesPage extends ConsumerStatefulWidget {
  const MyBadgesPage({super.key});

  @override
  ConsumerState<MyBadgesPage> createState() => _MyBadgesPageState();
}

class _MyBadgesPageState extends ConsumerState<MyBadgesPage> {
  Map<BadgeType, List<UserBadge>>? _groupedBadges;
  bool _isLoading = true;
  Object? _error;
  StackTrace? _errorStack;

  /// 宽屏左右栏：右侧当前展示的徽章（左侧点击切换，不压栈）。
  UserBadge? _selectedBadge;

  /// build 里存下的宽屏判定，供点击回调读（不能在回调里读 MediaQuery，
  /// 见 profile_page.dart 同类注释）。
  bool _showWideLayout = false;

  @override
  void initState() {
    super.initState();
    _loadBadges();
  }

  Future<void> _loadBadges() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _errorStack = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      if (user == null) {
        setState(() {
          _error = Exception(S.current.error_unauthorizedExpired);
          _isLoading = false;
        });
        return;
      }

      final service = ref.read(discourseServiceProvider);
      final response = await service.getUserBadges(username: user.username);

      final Map<BadgeType, List<UserBadge>> grouped = {};
      for (var userBadge in response.userBadges) {
        if (userBadge.badge == null) continue;
        final type = userBadge.badge!.badgeType;
        if (!grouped.containsKey(type)) {
          grouped[type] = [];
        }
        grouped[type]!.add(userBadge);
      }

      if (mounted) {
        setState(() {
          _groupedBadges = grouped;
          _isLoading = false;
        });
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

  @override
  Widget build(BuildContext context) {
    // Calculate total badges
    int totalCount = 0;
    if (_groupedBadges != null) {
      for (var list in _groupedBadges!.values) {
        totalCount += list.length;
      }
    }
    _showWideLayout = MasterDetailLayout.canShowBothPanesFor(context);

    final listBody = _isLoading
        ? const MyBadgesSkeleton()
        : _error != null
            ? ErrorView(
                error: _error!,
                stackTrace: _errorStack,
                onRetry: _loadBadges,
              )
            : M3eRefreshIndicator(
                onRefresh: _loadBadges,
                child: CustomScrollView(
                  slivers: [
                    _buildAppBar(context, totalCount),
                    if (_groupedBadges == null || _groupedBadges!.isEmpty)
                      SliverFillRemaining(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Symbols.military_tech_rounded,
                                  size: 64, color: Colors.grey[400]),
                              const SizedBox(height: 16),
                              Text(context.l10n.myBadges_empty,
                                  style: TextStyle(color: Colors.grey[600])),
                            ],
                          ),
                        ),
                      )
                    else ...[
                      const SliverPadding(padding: EdgeInsets.only(top: 16)),
                      _buildBadgeSection(BadgeType.gold),
                      _buildBadgeSection(BadgeType.silver),
                      _buildBadgeSection(BadgeType.bronze),
                      const SliverPadding(
                          padding: EdgeInsets.only(bottom: 48)),
                    ],
                  ],
                ),
              );

    if (!_showWideLayout) {
      // 宽 → 窄迁移:右栏正开着详情时拖窄窗口,把它转成一次全屏 push,
      // 不让已选中的内容静默消失(对齐话题列表 _maybePushDetail 的兜底)。
      // 本页被别的全屏页覆盖时不迁移(offstage 重建会把 BadgePage 推到
      // 用户当前页之上劫持栈顶);保留选中,等回到本页再按当时宽窄处理。
      final currentRoute = ModalRoute.of(context);
      final covered = currentRoute != null && !currentRoute.isCurrent;
      final migrate = covered ? null : _selectedBadge;
      if (migrate != null) {
        _selectedBadge = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // 一帧内又变宽(折叠屏铰链抖动):不迁移,直接恢复选中
          if (MasterDetailLayout.canShowBothPanesFor(context)) {
            setState(() => _selectedBadge = migrate);
            return;
          }
          final user = ref.read(currentUserProvider).value;
          Navigator.of(context).push(
            MaterialPageRoute(
              // AutoRestore:折叠屏折来折去的工况 —— 展开(变宽)时自动
              // 收回双栏并恢复网格选中,再折(变窄)又会走到这里转全屏。
              builder: (_) => AutoRestoreMasterDetailRoute(
                onRestore: () {
                  if (mounted) setState(() => _selectedBadge = migrate);
                },
                child: BadgePage(
                  badgeId: migrate.badge!.id,
                  badgeSlug: migrate.badge!.slug,
                  username: user?.username,
                ),
              ),
            ),
          );
        });
      }
      return Scaffold(body: listBody);
    }

    // 宽屏:标准平行视界(与全站一致:可拖拽分隔线、统一阈值与空态形态),
    // 点另一枚直接替换右栏,不走 Navigator push。
    return Scaffold(
      body: MasterDetailLayout(
        master: listBody,
        preferredMasterRatio: 0.5,
        maxMasterRatio: 0.65,
        detail: _selectedBadge == null
            ? null
            : BadgePage(
                key: ValueKey('badge_detail_${_selectedBadge!.badge!.id}'),
                badgeId: _selectedBadge!.badge!.id,
                badgeSlug: _selectedBadge!.badge!.slug,
                username: ref.read(currentUserProvider).value?.username,
                embeddedMode: true,
              ),
        emptyDetail: _buildDetailEmptyState(context),
      ),
    );
  }

  Widget _buildDetailEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.military_tech_rounded,
            size: 64,
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.myBadges_selectHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, int totalCount) {
    return SliverAppBar.large(
      title: Text(context.l10n.myBadges_title),
      centerTitle: false,
      expandedHeight: 200, // Taller header
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Theme.of(context).colorScheme.surface,
                Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                right: -20,
                top: -20,
                child: FaIcon(
                  FontAwesomeIcons.medal,
                  size: 200,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                ),
              ),
              Positioned(
                left: 20 + MediaQuery.of(context).padding.left,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.l10n.myBadges_totalEarned,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$totalCount',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.myBadges_badgeUnit,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBadgeSection(BadgeType type) {
    final badges = _groupedBadges?[type];
    if (badges == null || badges.isEmpty) return const SliverToBoxAdapter();

    final sectionColor = BadgeUIUtils.getSectionColor(context, type);
    final sectionTitle = BadgeUIUtils.getBadgeTypeName(type);
    final sectionIcon = BadgeUIUtils.getBadgeIcon(type);

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                FaIcon(sectionIcon, size: 20, color: sectionColor),
                const SizedBox(width: 12),
                Text(
                  sectionTitle,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: sectionColor,
                        fontSize: 18,
                      ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: sectionColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${badges.length}',
                    style: TextStyle(
                      color: sectionColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 1.35, // Safe middle ground
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                return _buildBadgeItem(badges[index], type);
              },
              childCount: badges.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBadgeItem(UserBadge userBadge, BadgeType type) {
    final badge = userBadge.badge!;
    final theme = Theme.of(context);
    final iconColor = BadgeUIUtils.getBadgeColor(context, type);

    return InkWell(
      onTap: () {
        final user = ref.read(currentUserProvider).value;
        if (user == null) return;
        if (_showWideLayout) {
          setState(() => _selectedBadge = userBadge);
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => BadgePage(
              badgeId: badge.id,
              badgeSlug: badge.slug,
              username: user.username,
            ),
          ),
        );
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BadgeUIUtils.getCardDecoration(context, type),
        // 宽屏右栏开着谁,网格上就框谁(此前没有任何选中反馈)
        foregroundDecoration:
            _showWideLayout && identical(_selectedBadge, userBadge)
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  )
                : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Count Badge (Corner) - Modern capsule style
            if (userBadge.count > 1)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: iconColor.withValues(alpha: 0.3), width: 1),
                  ),
                  child: Text(
                    '×${userBadge.count}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: iconColor,
                    ),
                  ),
                ),
              ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center, // Center the rigid block
                children: [
                   // Large Central Icon
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.surface,
                      boxShadow: [
                        BoxShadow(
                          color: iconColor.withValues(alpha: 0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        )
                      ],
                    ),
                    padding: const EdgeInsets.all(8), // Padding to prevent image touching edges
                    child: Center(
                      child: badge.imageUrl != null &&
                              badge.imageUrl!.isNotEmpty
                          ? Image(
                              image: discourseImageProvider(
                                UrlHelper.resolveUrlWithCdn(badge.imageUrl!),
                              ),
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  FaIcon(
                                    badge.icon != null &&
                                            badge.icon!.isNotEmpty
                                        ? (FontAwesomeHelper.getIcon(
                                              badge.icon!,
                                            ) ??
                                            BadgeUIUtils.getBadgeIcon(type))
                                        : BadgeUIUtils.getBadgeIcon(type),
                                    size: 24,
                                    color: iconColor,
                                  ),
                            )
                          : FaIcon(
                              badge.icon != null && badge.icon!.isNotEmpty
                                  ? (FontAwesomeHelper.getIcon(badge.icon!) ?? BadgeUIUtils.getBadgeIcon(type))
                                  : BadgeUIUtils.getBadgeIcon(type),
                              size: 24,
                              color: iconColor,
                            ),
                    ),
                  ),
                  const SizedBox(height: 4), // Minimal gap
                  // Name (Centered)
                  SizedBox(
                    height: 36, // Compact fixed height
                    child: Center(
                      child: Text(
                        badge.name,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
