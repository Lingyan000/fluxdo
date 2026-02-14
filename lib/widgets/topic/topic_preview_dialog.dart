import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../utils/color_utils.dart';
import '../../utils/url_helper.dart';
import '../../utils/font_awesome_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../utils/time_utils.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';
import '../common/topic_badges.dart';

/// 话题预览弹窗 - 长按卡片时显示
class TopicPreviewDialog extends ConsumerWidget {
  final Topic topic;
  final VoidCallback? onOpen;

  const TopicPreviewDialog({
    super.key,
    required this.topic,
    this.onOpen,
  });

  /// 显示预览弹窗
  static Future<void> show(
    BuildContext context, {
    required Topic topic,
    VoidCallback? onOpen,
  }) {
    // 触觉反馈
    HapticFeedback.mediumImpact();

    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭预览',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return TopicPreviewDialog(
          topic: topic,
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

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final category = categoryMap?[topic.categoryId];

    // 图标逻辑
    IconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
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
                      _buildTitle(context, theme),

                      const SizedBox(height: 12),

                      // 分类和标签
                      if (category != null || topic.tags.isNotEmpty)
                        _buildCategoryAndTags(context, theme, category, faIcon, logoUrl),

                      const SizedBox(height: 16),

                      // 摘要内容
                      if (topic.excerpt != null && topic.excerpt!.isNotEmpty)
                        _buildExcerpt(context, theme),

                      const SizedBox(height: 16),

                      // 统计信息
                      _buildStats(context, theme),
                    ],
                  ),
                ),
              ),

              // 底部操作栏
              _buildActions(context, theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context, ThemeData theme) {
    return Text.rich(
      TextSpan(
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.bold,
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
          if (topic.pinned)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          if (topic.hasAcceptedAnswer)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.check_box,
                  size: 20,
                  color: Colors.green,
                ),
              ),
            ),
          ...EmojiText.buildEmojiSpans(
            context,
            topic.title,
            theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryAndTags(
    BuildContext context,
    ThemeData theme,
    Category? category,
    IconData? faIcon,
    String? logoUrl,
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
              color: ColorUtils.parseHex(category.color).withValues(alpha:0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: ColorUtils.parseHex(category.color).withValues(alpha:0.3),
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
                      color: ColorUtils.parseHex(category.color),
                    ),
                  )
                else if (logoUrl != null && logoUrl.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Image(
                      image: discourseImageProvider(
                        UrlHelper.resolveUrl(logoUrl),
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

  Widget _buildExcerpt(BuildContext context, ThemeData theme) {
    // 清理 excerpt 中的 HTML 标签
    final cleanExcerpt = topic.excerpt!
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();

    if (cleanExcerpt.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        cleanExcerpt,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.6,
        ),
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildStats(BuildContext context, ThemeData theme) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        // 回复数
        _buildStatItem(
          context,
          Icons.chat_bubble_outline_rounded,
          '${(topic.postsCount - 1).clamp(0, 999999)} 条回复',
        ),

        // 点赞数
        if (topic.likeCount > 0)
          _buildStatItem(
            context,
            Icons.favorite_border_rounded,
            '${NumberUtils.formatCount(topic.likeCount)} 点赞',
          ),

        // 浏览数
        _buildStatItem(
          context,
          Icons.visibility_outlined,
          '${NumberUtils.formatCount(topic.views)} 浏览',
        ),

        // 时间
        _buildStatItem(
          context,
          Icons.access_time,
          TimeUtils.formatRelativeTime(topic.lastPostedAt),
        ),
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

  Widget _buildActions(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // 关闭按钮
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),

          const Spacer(),

          // 打开按钮
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onOpen?.call();
            },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('查看详情'),
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
        color: ColorUtils.parseHex(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

}
