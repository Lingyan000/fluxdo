import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../models/badge.dart';
import '../services/discourse/discourse_service.dart';
import '../widgets/common/relative_time_text.dart';
import '../utils/font_awesome_helper.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/url_helper.dart';
import '../widgets/common/loading_spinner.dart';
import '../widgets/badge/badge_ui_utils.dart';
import '../widgets/content/discourse_html_content/discourse_html_content_widget.dart';
import '../services/emoji_handler.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'user_profile_page.dart';
import '../l10n/s.dart';

/// 徽章详情页面
class BadgePage extends ConsumerStatefulWidget {
  final int badgeId;
  final String? badgeSlug;
  final String? username; // 可选，筛选特定用户

  const BadgePage({
    super.key,
    required this.badgeId,
    this.badgeSlug,
    this.username,
  });

  @override
  ConsumerState<BadgePage> createState() => _BadgePageState();
}

class _BadgePageState extends ConsumerState<BadgePage> {
  final DiscourseService _service = DiscourseService();
  BadgeDetailResponse? _badgeDetail;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBadgeDetail();
  }

  Future<void> _loadBadgeDetail() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final badge = await _service.getBadge(badgeId: widget.badgeId);
      final usersResponse = await _service.getBadgeUsers(
        badgeId: widget.badgeId,
        username: widget.username,
      );

      if (mounted) {
        setState(() {
          _badgeDetail = BadgeDetailResponse(
            badge: badge,
            userBadges: usersResponse.userBadges,
            grantedBies: usersResponse.grantedBies,
            totalCount: usersResponse.totalCount,
          );
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading badge detail: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _onRefresh() async {
    await _loadBadgeDetail();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isLoading
          ? const Center(child: LoadingSpinner())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text('${context.l10n.common_loadFailed}: $_error', style: const TextStyle(color: Colors.grey)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _onRefresh,
                        child: Text(context.l10n.common_retry),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: CustomScrollView(
                    slivers: [
                      // Modern Sliver App Bar
                      _buildSliverAppBar(context),
                      
                      // Badge Info Card (Floating effect)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                        sliver: SliverToBoxAdapter(
                          child: _BadgeInfoCard(badge: _badgeDetail!.badge),
                        ),
                      ),

                      // Users Header
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                        sliver: SliverToBoxAdapter(
                          child: Row(
                            children: [
                              Icon(
                                Icons.people_outline,
                                color: Theme.of(context).colorScheme.primary,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                context.l10n.badge_grantees,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 18,
                                    ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  context.l10n.badge_granteeCount(_badgeDetail!.totalCount),
                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // User List
                      _badgeDetail!.userBadges.isEmpty
                          ? SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.person_off_outlined,
                                      size: 48,
                                      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      context.l10n.badge_noGrantees,
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.outline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final userBadge = _badgeDetail!.userBadges[index];

                                  if (_badgeDetail!.grantedBies.isEmpty) {
                                    return const SizedBox.shrink();
                                  }

                                  // Safe user lookup
                                  final user = _badgeDetail!.grantedBies.firstWhere(
                                    (u) => u.id == userBadge.userId,
                                    orElse: () => _badgeDetail!.grantedBies.first,
                                  );

                                  return _UserBadgeItem(
                                    userBadge: userBadge,
                                    user: user,
                                  );
                                },
                                childCount: _badgeDetail!.userBadges.length,
                              ),
                            ),
                      const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSliverAppBar(BuildContext context) {
    final badge = _badgeDetail!.badge;
    final badgeType = badge.badgeType;
    final gradient = BadgeUIUtils.getHeaderGradient(context, badgeType);
    final iconColor = BadgeUIUtils.getBadgeColor(context, badgeType);

    return SliverAppBar(
      expandedHeight: 220,
      pinned: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      elevation: 0,
      iconTheme: IconThemeData(
        color: Theme.of(context).colorScheme.onSurface,
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(gradient: gradient),
          child: Center(
            child: _buildLargeBadgeIcon(badge, iconColor),
          ),
        ),
      ),
    );
  }

  Widget _buildLargeBadgeIcon(Badge badge, Color color) {
    if (badge.imageUrl != null && badge.imageUrl!.isNotEmpty) {
      return Image(
        image: discourseImageProvider(
          UrlHelper.resolveUrlWithCdn(badge.imageUrl!),
        ),
        width: 100,
        height: 100,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _buildIconFallback(badge, color, 100),
      );
    }
    return _buildIconFallback(badge, color, 100);
  }

  Widget _buildIconFallback(Badge badge, Color color, double size) {
    final iconData = badge.icon != null && badge.icon!.isNotEmpty
        ? (FontAwesomeHelper.getIcon(badge.icon!) ?? FontAwesomeIcons.medal)
        : FontAwesomeIcons.medal;
    return FaIcon(iconData, size: size, color: color);
  }
}

/// 徽章详细信息卡片
class _BadgeInfoCard extends StatelessWidget {
  final Badge badge;

  const _BadgeInfoCard({required this.badge});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badgeType = badge.badgeType;
    final badgeColor = BadgeUIUtils.getBadgeColor(context, badgeType);
    final typeName = BadgeUIUtils.getBadgeTypeName(badgeType);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Name and Type
          Text(
            badge.name,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: badgeColor.withValues(alpha: 0.2)),
            ),
            child: Text(
              typeName,
              style: TextStyle(
                color: badgeColor,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Descriptions
          DiscourseHtmlContent(
            html: EmojiHandler().replaceEmojis(badge.description),
            textStyle: theme.textTheme.bodyMedium?.copyWith(
              height: 1.6,
              fontSize: 16,
            ),
          ),

          if (badge.longDescription != null && badge.longDescription!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: DiscourseHtmlContent(
                html: EmojiHandler().replaceEmojis(badge.longDescription!),
                textStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
          Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
          const SizedBox(height: 16),
          
          // Grant Count
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.emoji_events_outlined,
                size: 20,
                color: theme.colorScheme.secondary,
              ),
              const SizedBox(width: 8),
              Text(
                context.l10n.badge_grantedCount(badge.grantCount),
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 用户列表项 - 现代化
class _UserBadgeItem extends StatelessWidget {
  final UserBadge userBadge;
  final BadgeUser user;

  const _UserBadgeItem({
    required this.userBadge,
    required this.user,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return InkWell(
      onTap: userBadge.topicId != null ? () => _navigateToTopic(context) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Expanded Avatar
            GestureDetector(
              onTap: () => _navigateToUser(context),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  backgroundImage: discourseImageProvider(user.getAvatarUrl()),
                ),
              ),
            ),
            const SizedBox(width: 16),
            
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name line
                  Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: () => _navigateToUser(context),
                          child: Text(
                            user.username,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (user.admin == true) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.shield, size: 14, color: Colors.red.shade700),
                      ] else if (user.moderator == true) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.shield, size: 14, color: Colors.blue.shade700),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  
                  // Date
                  RelativeTimeText(
                    dateTime: userBadge.grantedAt,
                    displayStyle: TimeDisplayStyle.suffixed,
                    suffix: context.l10n.badge_grantedSuffix,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),

                  // Topic Link
                  if (userBadge.topicTitle != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.article_outlined,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              userBadge.topicTitle!,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToUser(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfilePage(username: user.username),
      ),
    );
  }

  void _navigateToTopic(BuildContext context) {
    if (userBadge.topicId != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TopicDetailPage(
            topicId: userBadge.topicId!,
            scrollToPostNumber: userBadge.postNumber,
          ),
        ),
      );
    }
  }
}
