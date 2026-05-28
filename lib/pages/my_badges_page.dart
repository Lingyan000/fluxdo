import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../models/badge.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/url_helper.dart';
import '../widgets/badge/my_badges_skeleton.dart';
import '../utils/font_awesome_helper.dart';
import '../widgets/badge/badge_ui_utils.dart';
import 'badge_page.dart';
import '../l10n/s.dart';

/// 我的徽章页面
class MyBadgesPage extends ConsumerStatefulWidget {
  const MyBadgesPage({super.key});

  @override
  ConsumerState<MyBadgesPage> createState() => _MyBadgesPageState();
}

class _MyBadgesPageState extends ConsumerState<MyBadgesPage> {
  Map<BadgeType, List<UserBadge>>? _groupedBadges;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBadges();
  }

  Future<void> _loadBadges() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      if (user == null) {
        setState(() {
          _error = S.current.error_unauthorizedExpired;
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
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
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

    return Scaffold(
      body: _isLoading
          ? const MyBadgesSkeleton()
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text('${context.l10n.common_loadFailed}: $_error',
                          style: const TextStyle(color: Colors.grey)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadBadges,
                        child: Text(context.l10n.common_retry),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
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
                                Icon(Icons.military_tech_outlined,
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
                        fontWeight: FontWeight.bold,
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
                        fontWeight: FontWeight.bold,
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
                      fontWeight: FontWeight.bold,
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
        if (user != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => BadgePage(
                badgeId: badge.id,
                badgeSlug: badge.slug,
                username: user.username,
              ),
            ),
          );
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BadgeUIUtils.getCardDecoration(context, type),
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
                          fontWeight: FontWeight.bold,
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
