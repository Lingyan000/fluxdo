import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/topic.dart';
import '../../pages/image_viewer_page.dart';
import '../../providers/core_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/topic_excerpt_provider.dart';
import '../../services/topic_excerpt_service.dart';
import '../../services/toast_service.dart';
import '../common/cached_image.dart';

/// 类 X（原推特）风格可折叠展开的话题正文内容组件。
///
/// 特性：
/// 1. 默认超出 8 行自动折叠，末尾提供“查看更多”交互按钮；
/// 2. 点击平滑展开全部内容，并切换为“收起”按钮；
/// 3. 支持类 X 风格 1~4 宫格媒体缩略图排版，点击图片平滑进入大图画廊查看；
/// 4. 支持无需进入详情页快速复制文本：长按正文或点击工具栏“复制”小图标一键复制全文；
/// 5. 交互手势严格隔离，避免向上冒泡触发整卡跳转。
class TopicExpandableExcerpt extends ConsumerStatefulWidget {
  final Topic topic;

  /// 默认折叠行数，按需求设定为 8 行
  final int maxCollapsedLines;

  /// 是否为已读状态（退灰）
  final bool isFullyRead;

  /// 自定义文本样式（若不传则自动适配当前主题与字号缩放）
  final TextStyle? style;

  const TopicExpandableExcerpt({
    super.key,
    required this.topic,
    this.maxCollapsedLines = 8,
    this.isFullyRead = false,
    this.style,
  });

  @override
  ConsumerState<TopicExpandableExcerpt> createState() => _TopicExpandableExcerptState();
}

class _TopicExpandableExcerptState extends ConsumerState<TopicExpandableExcerpt> {
  bool _isExpanded = false;
  TopicExcerptData? _excerptData;

  @override
  void initState() {
    super.initState();
    _loadExcerpt();
  }

  @override
  void didUpdateWidget(covariant TopicExpandableExcerpt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic.id != widget.topic.id ||
        oldWidget.topic.excerpt != widget.topic.excerpt) {
      _loadExcerpt();
    }
  }

  void _loadExcerpt() {
    final service = ref.read(topicExcerptServiceProvider);
    final cached = service.getCached(
      widget.topic.id,
      fallbackRaw: widget.topic.excerpt,
    );

    if (cached != null && cached.isNotEmpty) {
      _excerptData = cached;
      return;
    }

    _excerptData = null;
    // 异步排队拉取首楼摘要与媒体
    Future.microtask(() async {
      if (!mounted) return;
      final data = await ref.read(topicExcerptServiceProvider).getOrFetchExcerpt(
        widget.topic.id,
        fallbackRaw: widget.topic.excerpt,
        service: ref.read(discourseServiceProvider),
      );
      if (mounted && data != null && data.isNotEmpty) {
        setState(() {
          _excerptData = data;
        });
      }
    });
  }

  /// 复制全文到剪贴板
  void _copyContent(String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ToastService.showSuccess('已复制帖子内容');
  }

  @override
  Widget build(BuildContext context) {
    final data = _excerptData;
    if (data == null || data.isEmpty) {
      return const SizedBox.shrink();
    }

    final text = data.text;
    final images = data.imageUrls;
    final theme = Theme.of(context);
    final contentFontScale = ref.watch(preferencesProvider.select((p) => p.contentFontScale));

    // 计算符合 X 风格的文本样式：行高 1.45，适宜移动端舒适阅读
    final baseFontSize = 13.5 * contentFontScale;
    final textColor = widget.isFullyRead
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
        : theme.colorScheme.onSurfaceVariant;

    final effectiveTextStyle = widget.style ??
        theme.textTheme.bodyMedium?.copyWith(
          fontSize: baseFontSize,
          height: 1.45,
          color: textColor,
          letterSpacing: 0.1,
        );

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      alignment: Alignment.topLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          bool exceeds = false;

          if (text.isNotEmpty) {
            // 精确测量当前宽度与行数约束下是否溢出 8 行
            final textSpan = TextSpan(text: text, style: effectiveTextStyle);
            final textPainter = TextPainter(
              text: textSpan,
              textDirection: Directionality.of(context),
              maxLines: widget.maxCollapsedLines,
            )..layout(maxWidth: maxWidth);

            exceeds = textPainter.didExceedMaxLines;
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. 正文文字区域（支持长按快速复制）
              if (text.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _copyContent(text),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 2),
                    child: Text(
                      text,
                      style: effectiveTextStyle,
                      maxLines: _isExpanded ? null : widget.maxCollapsedLines,
                      overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                    ),
                  ),
                ),

              // 2. 媒体图片九宫格展示（类似 X/推特图片网格）
              if (images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: _buildMediaGrid(context, images, maxWidth),
                ),

              // 3. 底部轻量交互栏：展开/收起按钮 + 快速复制小按钮
              if (text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (exceeds)
                        _buildToggleButton(context, theme)
                      else
                        const SizedBox.shrink(),
                      _buildCopyButton(context, theme, text),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 展开 / 收起按钮
  Widget _buildToggleButton(BuildContext context, ThemeData theme) {
    final primaryColor = theme.colorScheme.primary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _isExpanded = !_isExpanded;
        });
      },
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _isExpanded ? '收起' : '查看更多',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: primaryColor,
                  height: 1.2,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                _isExpanded
                    ? Symbols.expand_less_rounded
                    : Symbols.expand_more_rounded,
                size: 16,
                color: primaryColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 快速复制小按钮（免进入详情页）
  Widget _buildCopyButton(BuildContext context, ThemeData theme, String text) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _copyContent(text),
      child: Tooltip(
        message: '复制帖子内容',
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Symbols.content_copy_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 3),
                Text(
                  '复制',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建推特/X 风格图片网格（1~4 张缩略图）
  Widget _buildMediaGrid(BuildContext context, List<String> images, double maxWidth) {
    const double radius = 8.0;
    const double gap = 4.0;

    if (images.length == 1) {
      // 1 张大图展示
      return _buildImageItem(
        context: context,
        url: images[0],
        index: 0,
        images: images,
        height: 170,
        width: maxWidth,
        borderRadius: BorderRadius.circular(radius),
      );
    } else if (images.length == 2) {
      // 2 张双列并排
      final itemWidth = (maxWidth - gap) / 2;
      return Row(
        children: [
          _buildImageItem(
            context: context,
            url: images[0],
            index: 0,
            images: images,
            height: 125,
            width: itemWidth,
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(radius)),
          ),
          const SizedBox(width: gap),
          _buildImageItem(
            context: context,
            url: images[1],
            index: 1,
            images: images,
            height: 125,
            width: itemWidth,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(radius)),
          ),
        ],
      );
    } else if (images.length == 3) {
      // 3 张图：左 1 大图，右 2 小图上下排
      final leftWidth = (maxWidth - gap) * 0.58;
      final rightWidth = (maxWidth - gap) * 0.42;
      const double totalHeight = 160;
      final itemHeight = (totalHeight - gap) / 2;

      return SizedBox(
        height: totalHeight,
        child: Row(
          children: [
            _buildImageItem(
              context: context,
              url: images[0],
              index: 0,
              images: images,
              height: totalHeight,
              width: leftWidth,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(radius)),
            ),
            const SizedBox(width: gap),
            Column(
              children: [
                _buildImageItem(
                  context: context,
                  url: images[1],
                  index: 1,
                  images: images,
                  height: itemHeight,
                  width: rightWidth,
                  borderRadius: const BorderRadius.only(topRight: Radius.circular(radius)),
                ),
                const SizedBox(height: gap),
                _buildImageItem(
                  context: context,
                  url: images[2],
                  index: 2,
                  images: images,
                  height: itemHeight,
                  width: rightWidth,
                  borderRadius: const BorderRadius.only(bottomRight: Radius.circular(radius)),
                ),
              ],
            ),
          ],
        ),
      );
    } else {
      // 4 张 2x2 经典四宫格
      final itemWidth = (maxWidth - gap) / 2;
      const double itemHeight = 95;

      return Column(
        children: [
          Row(
            children: [
              _buildImageItem(
                context: context,
                url: images[0],
                index: 0,
                images: images,
                height: itemHeight,
                width: itemWidth,
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(radius)),
              ),
              const SizedBox(width: gap),
              _buildImageItem(
                context: context,
                url: images[1],
                index: 1,
                images: images,
                height: itemHeight,
                width: itemWidth,
                borderRadius: const BorderRadius.only(topRight: Radius.circular(radius)),
              ),
            ],
          ),
          const SizedBox(height: gap),
          Row(
            children: [
              _buildImageItem(
                context: context,
                url: images[2],
                index: 2,
                images: images,
                height: itemHeight,
                width: itemWidth,
                borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(radius)),
              ),
              const SizedBox(width: gap),
              _buildImageItem(
                context: context,
                url: images[3],
                index: 3,
                images: images,
                height: itemHeight,
                width: itemWidth,
                borderRadius: const BorderRadius.only(bottomRight: Radius.circular(radius)),
              ),
            ],
          ),
        ],
      );
    }
  }

  /// 单个图片小块，带有手势拦截与全屏大图预览接入
  Widget _buildImageItem({
    required BuildContext context,
    required String url,
    required int index,
    required List<String> images,
    required double height,
    required double width,
    required BorderRadius borderRadius,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        ImageViewerPage.open(
          context,
          url,
          galleryImages: images,
          initialIndex: index,
        );
      },
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox(
          width: width,
          height: height,
          child: CachedImage(
            url: url,
            fit: BoxFit.cover,
            thumbnailMode: true,
            placeholder: (context) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
