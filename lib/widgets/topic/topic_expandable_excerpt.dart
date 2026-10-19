import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../pages/image_viewer_page.dart';
import '../../providers/core_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/topic_excerpt_provider.dart';
import '../../services/topic_excerpt_service.dart';
import '../../services/toast_service.dart';
import '../common/cached_image.dart';

/// 列表内容预览：文字和图片分别控制，首楼补充请求单独授权。
class TopicExpandableExcerpt extends ConsumerStatefulWidget {
  final Topic topic;
  final int maxCollapsedLines;
  final bool showText;
  final bool showImages;
  final bool allowFetch;
  final bool isFullyRead;
  final TextStyle? style;

  const TopicExpandableExcerpt({
    super.key,
    required this.topic,
    this.maxCollapsedLines = 3,
    this.showText = true,
    this.showImages = false,
    this.allowFetch = false,
    this.isFullyRead = false,
    this.style,
  });

  @override
  ConsumerState<TopicExpandableExcerpt> createState() =>
      _TopicExpandableExcerptState();
}

class _TopicExpandableExcerptState
    extends ConsumerState<TopicExpandableExcerpt> {
  bool _isExpanded = false;
  TopicExcerptData? _excerptData;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadExcerpt();
  }

  @override
  void didUpdateWidget(covariant TopicExpandableExcerpt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic.id != widget.topic.id ||
        oldWidget.topic.excerpt != widget.topic.excerpt ||
        oldWidget.topic.imageUrl != widget.topic.imageUrl ||
        oldWidget.showText != widget.showText ||
        oldWidget.showImages != widget.showImages ||
        oldWidget.allowFetch != widget.allowFetch) {
      if (oldWidget.topic.id != widget.topic.id) _isExpanded = false;
      _loadExcerpt();
    }
  }

  void _loadExcerpt() {
    final generation = ++_loadGeneration;
    final topic = widget.topic;
    final service = ref.read(topicExcerptServiceProvider);
    _excerptData = service.getCached(
      topic.id,
      fallbackRaw: topic.excerpt,
      fallbackImageUrl: topic.imageUrl,
    );
    if (!widget.allowFetch || (!widget.showText && !widget.showImages)) return;
    Future.microtask(() async {
      if (!mounted || generation != _loadGeneration) return;
      final data = await service.getOrFetchExcerpt(
        topic.id,
        fallbackRaw: topic.excerpt,
        fallbackImageUrl: topic.imageUrl,
        service: ref.read(discourseServiceProvider),
        allowFetch: true,
      );
      if (mounted && generation == _loadGeneration && data != null) {
        setState(() => _excerptData = data);
      }
    });
  }

  void _copyContent(String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ToastService.showSuccess(context.l10n.topicCardStyle_excerptCopied);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.showText ? _excerptData?.text ?? '' : '';
    final images = widget.showImages
        ? _excerptData?.imageUrls ?? const <String>[]
        : const <String>[];
    if (text.isEmpty && images.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scale = ref.watch(
      preferencesProvider.select((p) => p.contentFontScale),
    );
    final textStyle =
        widget.style ??
        theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13 * scale,
          height: 1.45,
          color: theme.colorScheme.onSurfaceVariant.withValues(
            alpha: widget.isFullyRead ? 0.7 : 1,
          ),
        );
    // 收起时压平段落空白；展开后恢复原始段落，避免空行占满列表。
    final compactText = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return LayoutBuilder(
      builder: (context, constraints) {
        var measuredStyle = DefaultTextStyle.of(context).style.merge(textStyle);
        if (MediaQuery.boldTextOf(context)) {
          measuredStyle = measuredStyle.copyWith(fontWeight: FontWeight.bold);
        }
        final painter = TextPainter(
          text: TextSpan(text: compactText, style: measuredStyle),
          textDirection: Directionality.of(context),
          maxLines: widget.maxCollapsedLines,
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final exceeds = painter.didExceedMaxLines;
        painter.dispose();

        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (text.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _copyContent(text),
                  child: Text(
                    _isExpanded ? text : compactText,
                    style: textStyle,
                    maxLines: _isExpanded ? null : widget.maxCollapsedLines,
                    overflow: _isExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (exceeds)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(48, 44),
                    alignment: Alignment.centerLeft,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.labelMedium,
                  ),
                  onPressed: () => setState(() => _isExpanded = !_isExpanded),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isExpanded
                            ? context.l10n.topicCardStyle_collapseExcerpt
                            : context.l10n.topicCardStyle_expandExcerpt,
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        _isExpanded
                            ? Symbols.expand_less_rounded
                            : Symbols.expand_more_rounded,
                        size: 16,
                      ),
                    ],
                  ),
                ),
            ],
            if (images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: _buildImages(context, images, constraints.maxWidth),
              ),
          ],
        );
        if (MediaQuery.disableAnimationsOf(context)) return content;
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topLeft,
          child: content,
        );
      },
    );
  }

  /// 限高的图片条，避免多图话题挤占整屏；点击仍可查看全部图片。
  Widget _buildImages(
    BuildContext context,
    List<String> images,
    double maxWidth,
  ) {
    final count = images.length.clamp(1, 3);
    final width = (maxWidth - (count - 1) * 6) / count;
    final height = count == 1 ? (maxWidth * 9 / 16).clamp(80.0, 144.0) : 104.0;
    return Row(
      children: [
        for (var index = 0; index < count; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          SizedBox(
            width: width,
            height: height,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => ImageViewerPage.open(
                  context,
                  images[index],
                  galleryImages: images,
                  initialIndex: index,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedImage(
                      url: images[index],
                      fit: BoxFit.cover,
                      thumbnailMode: true,
                      memCacheWidth:
                          (width * MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                    ),
                    if (index == count - 1 && images.length > count)
                      ColoredBox(
                        color: Colors.black45,
                        child: Center(
                          child: Text(
                            '+${images.length - count}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
