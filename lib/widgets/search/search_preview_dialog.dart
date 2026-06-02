import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/share_utils.dart';
import '../../utils/url_helper.dart';
import '../../utils/number_utils.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/smart_avatar.dart';
import '../common/topic_badges.dart';

/// 搜索结果预览弹窗 - 长按搜索卡片时显示
class SearchPreviewDialog extends ConsumerWidget {
  final SearchPost post;
  final VoidCallback? onOpen;

  const SearchPreviewDialog({
    super.key,
    required this.post,
    this.onOpen,
  });

  /// 显示预览弹窗
  static Future<void> show(
    BuildContext context, {
    required SearchPost post,
    VoidCallback? onOpen,
  }) {
    // 触觉反馈
    HapticFeedback.mediumImpact();

    return showAppGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: S.current.common_closePreview,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return SearchPreviewDialog(
          post: post,
          onOpen: onOpen,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return ScaleTransition(
          scale: curvedAnimation,
          child: FadeTransition(
            opacity: animation,
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final maxWidth = screenSize.width * 0.9;
    final maxHeight = screenSize.height * 0.7;
    final topic = post.topic;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = topic?.categoryId;
    Category? category;
    if (categoryId != null && categoryMap != null) {
      category = categoryMap[categoryId];
    }

    // 图标逻辑
    FaIconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.clamp(300, 500),
          maxHeight: maxHeight,
        ),
        child: Material(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          elevation: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部装饰条
              Container(
                height: 4,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primaryContainer,
                      theme.colorScheme.tertiaryContainer,
                    ],
                  ),
                ),
              ),

              // 内容区域
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 标题
                      if (topic != null) _buildTitle(context, theme, topic),

                      const SizedBox(height: 12),

                      // 作者信息
                      _buildAuthorInfo(context, theme),

                      // 分类和标签
                      if (category != null ||
                          (topic != null && topic.tags.isNotEmpty)) ...[
                        const SizedBox(height: 12),
                        _buildCategoryAndTags(
                            context, theme, category, faIcon, logoUrl, topic),
                      ],

                      // 摘要内容
                      if (post.blurb.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _buildBlurb(context, theme, ref),
                      ],

                      const SizedBox(height: 16),

                      // 统计信息
                      _buildStats(context, theme, topic),
                    ],
                  ),
                ),
              ),

              // 底部操作栏
              _buildActions(context, theme, ref),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(
      BuildContext context, ThemeData theme, SearchTopic topic) {
    return Text.rich(
      TextSpan(
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        children: [
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.lock_outline,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (topic.archived)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.archive_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          TextSpan(text: topic.title),
        ],
      ),
    );
  }

  Widget _buildAuthorInfo(BuildContext context, ThemeData theme) {
    final avatarUrl = post.getAvatarUrl(size: 56);

    return Row(
      children: [
        SmartAvatar(
          imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
          radius: 14,
          fallbackText: post.username,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            post.username,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (post.postNumber > 1) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '·',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '#${post.postNumber}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCategoryAndTags(
    BuildContext context,
    ThemeData theme,
    Category? category,
    FaIconData? faIcon,
    String? logoUrl,
    SearchTopic? topic,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 分类
        if (category != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _parseColor(category.color).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _parseColor(category.color).withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (faIcon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FaIcon(
                      faIcon,
                      size: 12,
                      color: _parseColor(category.color),
                    ),
                  )
                else if (logoUrl != null && logoUrl.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Image(
                      image: discourseImageProvider(
                        UrlHelper.resolveUrlWithCdn(logoUrl),
                      ),
                      width: 12,
                      height: 12,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return _buildCategoryDot(category);
                      },
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _buildCategoryDot(category),
                  ),
                Text(
                  category.name,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),

        // 标签
        if (topic != null)
          ...topic.tags.map(
            (tag) => TagBadge(
              name: tag.name,
              size: const BadgeSize(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                radius: 8,
                iconSize: 12,
                fontSize: 13,
              ),
              textStyle: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBlurb(BuildContext context, ThemeData theme, WidgetRef ref) {
    // 清理 blurb 中的 HTML 标签
    final cleanBlurb = post.blurb
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();

    if (cleanBlurb.isEmpty) return const SizedBox.shrink();

    final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        cleanBlurb,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.6,
          fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
        ),
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildStats(
      BuildContext context, ThemeData theme, SearchTopic? topic) {
    return Column(
      children: [
        Row(
          children: [
            if (topic != null)
              Expanded(
                child: _buildStatItem(
                  context,
                  Icons.chat_bubble_outline_rounded,
                  context.l10n.search_replyCount((topic.postsCount - 1).clamp(0, 999999)),
                ),
              ),
            if (post.likeCount > 0)
              Expanded(
                child: _buildStatItem(
                  context,
                  Icons.favorite_border_rounded,
                  context.l10n.search_likeCount(NumberUtils.formatCount(post.likeCount)),
                ),
              ),
          ],
        ),
        if (topic != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  context,
                  Icons.visibility_outlined,
                  context.l10n.search_viewCount(NumberUtils.formatCount(topic.views)),
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildStatItem(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, ThemeData theme, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // 关闭按钮
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.common_close),
          ),

          const Spacer(),

          // 分享按钮
          if (post.topic != null)
            IconButton(
              onPressed: () {
                final user = ref.read(currentUserProvider).value;
                final prefs = ref.read(preferencesProvider);
                final url = ShareUtils.buildShareUrl(
                  path: '/t/topic/${post.topic!.id}',
                  username: user?.username,
                  anonymousShare: prefs.anonymousShare,
                );
                SharePlus.instance.share(ShareParams(text: url));
              },
              icon: const Icon(Icons.share_outlined, size: 20),
              tooltip: context.l10n.common_share,
            ),

          const SizedBox(width: 8),

          // 打开按钮
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onOpen?.call();
            },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(context.l10n.common_viewDetails),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
