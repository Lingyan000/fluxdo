import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/s.dart';
import '../../models/category.dart';
import '../../models/search_result.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/color_utils.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/share_utils.dart';
import '../../utils/number_utils.dart';
import '../common/morphing_dialog_shell.dart';
import '../common/relative_time_text.dart';
import '../common/smart_avatar.dart';
import '../../pages/category_topics_page.dart';
import '../../pages/tag_topics_page.dart';

/// 搜索结果预览弹窗 - 长按搜索卡片时显示
///
/// 排版与 [TopicPreviewDialog] 同款(标题置顶 + 元信息行 + 轻文本标签 +
/// 纯文本摘要 + 统计/操作合一底栏);正文是搜索返回的 blurb(本地数据,
/// 无需加载)。传入 anchorRect 时走一镜到底容器变形(见
/// [MorphingDialogShell]),未传入回退中心缩放(防御兜底)。
class SearchPreviewDialog extends ConsumerWidget {
  final SearchPost post;
  final VoidCallback? onOpen;

  /// 一镜到底模式:非空时弹窗壳从 [anchorRect] 连续变形到居中弹窗,
  /// 关闭沿同路径收回(由路由 animation 驱动)
  final Animation<double>? morphAnimation;
  final Rect? anchorRect;
  final Color? anchorColor;
  final double anchorRadius;

  const SearchPreviewDialog({
    super.key,
    required this.post,
    this.onOpen,
    this.morphAnimation,
    this.anchorRect,
    this.anchorColor,
    this.anchorRadius = 10,
  });

  /// 显示预览弹窗
  static Future<void> show(
    BuildContext context, {
    required SearchPost post,
    VoidCallback? onOpen,
    Rect? anchorRect,
    Color? anchorColor,
    double anchorRadius = 10,
  }) {
    // 触觉反馈
    HapticFeedback.mediumImpact();

    if (anchorRect != null) {
      // 一镜到底:变形由弹窗内部根据路由 animation 自驱(MorphingDialogShell),
      // transitionBuilder 必须恒等 —— 默认整页淡入会让壳从透明浮现
      return showAppGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: S.current.common_closePreview,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 350),
        transitionBuilder: (context, animation, secondaryAnimation, child) =>
            child,
        pageBuilder: (context, animation, secondaryAnimation) {
          return SearchPreviewDialog(
            post: post,
            onOpen: onOpen,
            morphAnimation: animation,
            anchorRect: anchorRect,
            anchorColor: anchorColor,
            anchorRadius: anchorRadius,
          );
        },
      );
    }

    return showAppGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: S.current.common_closePreview,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return SearchPreviewDialog(post: post, onOpen: onOpen);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return ScaleTransition(
          scale: curvedAnimation,
          child: FadeTransition(opacity: animation, child: child),
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

    final morphing = morphAnimation != null;

    // 壳体内容:整体滚动区(标题/元信息/标签/摘要一起滚) + 固定底栏
    final sheetBody = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (topic != null) _buildTitle(context, theme, topic),
                const SizedBox(height: 8),
                _buildMetaRow(context, theme, category),
                if (topic != null && topic.tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _buildTagsLine(context, theme, topic),
                ],
                if (post.blurb.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildBlurb(context, theme, ref),
                ],
              ],
            ),
          ),
        ),
        _buildBottomBar(context, theme, ref, topic),
      ],
    );

    final contentColumn = Column(
      key: const ValueKey('search-preview-root'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          // 一镜到底模式的底色/圆角/阴影/裁剪全由飞行壳提供,这里只留
          // transparency Material 作 InkWell 载体,避免双层壳叠加
          child: morphing
              ? Material(type: MaterialType.transparency, child: sheetBody)
              : Material(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  elevation: 8,
                  child: sheetBody,
                ),
        ),
      ],
    );

    if (morphing) {
      return MorphingDialogShell(
        animation: morphAnimation!,
        anchorRect: anchorRect!,
        anchorColor: anchorColor,
        anchorRadius: anchorRadius,
        child: contentColumn,
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.clamp(300, 500),
          maxHeight: maxHeight,
        ),
        child: contentColumn,
      ),
    );
  }

  Widget _buildTitle(BuildContext context, ThemeData theme, SearchTopic topic) {
    // 17pt w600:与话题预览一致;最多 3 行防爆版
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    return Text.rich(
      TextSpan(
        style: titleStyle,
        children: [
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(
                  Symbols.lock_rounded,
                  size: 17,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (topic.archived)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Icon(
                  Symbols.archive_rounded,
                  size: 17,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          TextSpan(text: topic.title),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 头部元信息行:头像 + 昵称 · 分类(可点) · 帖子时间;右端 #楼层徽章
  Widget _buildMetaRow(
    BuildContext context,
    ThemeData theme,
    Category? category,
  ) {
    final avatarUrl = post.getAvatarUrl(size: 40);
    final metaColor = theme.colorScheme.onSurfaceVariant;
    final separator = Text(
      '·',
      style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
    );

    return Row(
      children: [
        SmartAvatar(
          imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
          radius: 10,
          fallbackText: post.username,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  post.username,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (category != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: separator,
                ),
                Flexible(
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              CategoryTopicsPage(category: category),
                        ),
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCategoryDot(context, category),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            category.name,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: metaColor,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: separator,
              ),
              RelativeTimeText(
                dateTime: post.createdAt,
                style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
              ),
            ],
          ),
        ),
        if (post.postNumber > 1) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '#${post.postNumber}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: metaColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 标签轻文本行:与话题卡片(CategoryTagsLine)同款 —— "#" 前缀 60%
  /// 透明度 + 中性色名,可点跳标签页
  Widget _buildTagsLine(
    BuildContext context,
    ThemeData theme,
    SearchTopic topic,
  ) {
    final metaColor = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(color: metaColor);
    final hashStyle = theme.textTheme.labelSmall?.copyWith(
      color: metaColor.withValues(alpha: 0.6),
    );
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        for (final tag in topic.tags)
          GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TagTopicsPage(tagName: tag.name),
                ),
              );
            },
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '#', style: hashStyle),
                  TextSpan(text: tag.name),
                ],
              ),
              style: style,
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
    // 纯文本无色块:预览是轻量一瞥,摘要不需要卡片式衬底
    return Text(
      cleanBlurb,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.6,
        fontSize:
            (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
      ),
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 底栏:统计(💬回复 ❤点赞 👁浏览,内联小字)与操作(分享/查看详情)
  /// 合一。无关闭按钮 —— 点遮罩/返回手势即关,与现代预览一致
  Widget _buildBottomBar(
    BuildContext context,
    ThemeData theme,
    WidgetRef ref,
    SearchTopic? topic,
  ) {
    final metaColor = theme.colorScheme.onSurfaceVariant;
    final statStyle = theme.textTheme.labelSmall?.copyWith(
      color: metaColor,
      fontWeight: FontWeight.w500,
    );

    Widget stat(IconData icon, int count) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: metaColor),
        const SizedBox(width: 3),
        Text(NumberUtils.formatCount(count), style: statStyle),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
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
          if (topic != null) ...[
            stat(
              Symbols.chat_bubble_rounded,
              (topic.postsCount - 1).clamp(0, 999999),
            ),
            const SizedBox(width: 14),
          ],
          stat(Symbols.favorite_border_rounded, post.likeCount),
          if (topic != null) ...[
            const SizedBox(width: 14),
            stat(Symbols.visibility_rounded, topic.views),
          ],
          const Spacer(),
          // 分享
          if (topic != null)
            IconButton(
              onPressed: () {
                final user = ref.read(currentUserProvider).value;
                final prefs = ref.read(preferencesProvider);
                final url = ShareUtils.buildShareUrl(
                  path: '/t/topic/${topic.id}',
                  username: user?.username,
                  anonymousShare: prefs.anonymousShare,
                );
                SharePlus.instance.share(ShareParams(text: url));
              },
              icon: const Icon(Symbols.share_rounded, size: 20),
              tooltip: context.l10n.common_share,
              visualDensity: VisualDensity.compact,
            ),
          const SizedBox(width: 4),
          // 查看详情(主操作)
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onOpen?.call();
            },
            icon: const Icon(Symbols.open_in_new_rounded, size: 18),
            label: Text(context.l10n.common_viewDetails),
          ),
        ],
      ),
    );
  }

  /// 分类色标:与话题卡片(CategoryTagsLine)同款 8px 圆角方形色块,
  /// 颜色经 ColorUtils.readableOn 按主题亮度适配
  Widget _buildCategoryDot(BuildContext context, Category category) {
    final theme = Theme.of(context);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: ColorUtils.readableOn(
          _parseColor(category.color),
          theme.brightness,
        ),
        borderRadius: BorderRadius.circular(2),
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
