import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/topic.dart';
import '../../../pages/topic_detail_page/topic_detail_page.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/html_parse_service.dart';
import '../../content/collapsed_html_content.dart';
import '../../content/discourse_html_content/chunked/chunked_html_content.dart';
import '../../content/discourse_html_content/chunked/html_chunk.dart';
import '../small_action_item.dart';
import 'widgets/post_footer_section/post_footer_section.dart';
import 'widgets/post_header_section.dart';
import 'widgets/post_segment_frame.dart';

class LongPostRenderData {
  final List<HtmlChunk> chunks;
  final List<String> galleryImages;
  final Set<String> spoilerImageUrls;
  final Set<String> revealedImageUrls;

  LongPostRenderData({
    required this.chunks,
    required this.galleryImages,
    required this.spoilerImageUrls,
    Set<String>? revealedImageUrls,
  }) : revealedImageUrls = revealedImageUrls ?? <String>{};

  factory LongPostRenderData.fromHtml(String html) {
    // 短帖子不分块,直接返回空 chunks 让外层走短帖路径。
    if (html.length <= ChunkedHtmlContent.chunkThreshold) {
      return LongPostRenderData(
        chunks: const <HtmlChunk>[],
        galleryImages: const <String>[],
        spoilerImageUrls: <String>{},
      );
    }

    // 一次解析同时拿到 chunks + gallery,避免重复 DOM 解析。
    // 详情页 ref.listen 中已经 preload,这里 parseSync 通常命中缓存零成本。
    final parsed = HtmlParseService.instance.parseSync(html);
    if (parsed.chunks.length <= 1) {
      return LongPostRenderData(
        chunks: const <HtmlChunk>[],
        galleryImages: parsed.galleryInfo.images,
        spoilerImageUrls: parsed.galleryInfo.spoilerImageUrls,
      );
    }

    return LongPostRenderData(
      chunks: parsed.chunks,
      galleryImages: parsed.galleryInfo.images,
      spoilerImageUrls: parsed.galleryInfo.spoilerImageUrls,
    );
  }
}

class LongPostHeaderSegment extends StatelessWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final bool isTopicOwner;
  final String? dateSeparatorLabel;
  final bool showDivider;
  final void Function(int postNumber)? onJumpToPost;

  const LongPostHeaderSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    required this.isTopicOwner,
    required this.dateSeparatorLabel,
    required this.showDivider,
    required this.onJumpToPost,
  });

  @override
  Widget build(BuildContext context) {
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      isTopicOwner: isTopicOwner,
      eyeCareBubblePart: EyeCareBubblePart.start,
      showTopDateSeparator: dateSeparatorLabel != null,
      topDateSeparatorLabel: dateSeparatorLabel,
      showDivider: showDivider,
      showBottomBorder: false,
      child: SelectionContainer.disabled(
        child: PostHeaderSection(
          post: post,
          topicId: topicId,
          isTopicOwner: isTopicOwner,
          showStamp: post.acceptedAnswer,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          onJumpToPost: onJumpToPost,
        ),
      ),
    );
  }
}

class LongPostChunkSegment extends ConsumerWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final bool isTopicOwner;
  final HtmlChunk chunk;
  final LongPostRenderData renderData;
  final void Function(String quote, Post post)? onQuoteImage;

  const LongPostChunkSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    this.isTopicOwner = false,
    required this.chunk,
    required this.renderData,
    required this.onQuoteImage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isModeratorAction = post.postType == PostTypes.moderatorAction;
    final contentTextStyle = theme.textTheme.bodyMedium?.copyWith(
      height: 1.5,
      fontSize:
          (theme.textTheme.bodyMedium?.fontSize ?? 14) *
          ref.watch(preferencesProvider).contentFontScale,
    );

    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      isTopicOwner: isTopicOwner,
      eyeCareBubblePart: EyeCareBubblePart.middle,
      showBottomBorder: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          decoration: isModeratorAction
              ? BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: 0.2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          padding: isModeratorAction
              ? const EdgeInsets.all(12)
              : EdgeInsets.zero,
          child: HtmlChunkWidget(
            chunk: chunk,
            textStyle: contentTextStyle,
            onInternalLinkTap: (topicId, topicSlug, postNumber) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TopicDetailPage(
                    topicId: topicId,
                    initialTitle: topicSlug,
                    scrollToPostNumber: postNumber,
                  ),
                ),
              );
            },
            linkCounts: post.linkCounts,
            galleryImages: renderData.galleryImages,
            spoilerImageUrls: renderData.spoilerImageUrls,
            revealedImageUrls: renderData.revealedImageUrls,
            mentionedUsers: post.mentionedUsers,
            fullHtml: post.cooked,
            post: post,
            topicId: topicId,
            enableSelectionArea: false,
            onQuoteImage: onQuoteImage,
          ),
        ),
      ),
    );
  }
}

class LongPostFooterSegment extends ConsumerWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final bool isTopicOwner;
  final bool topicHasAcceptedAnswer;
  final List<AcceptedAnswer> acceptedAnswers;
  final String? bottomDateSeparatorLabel;
  final void Function({String? initialContent})? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onShareAsImage;
  final void Function(int postId)? onRefreshPost;
  final void Function(int postNumber)? onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool useReplyDialog;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final bool isPmWithNonHumanUser;
  final VoidCallback? onShowPostDetail;
  final String? highlightBoostUsername;

  /// OP 帖专属插槽: 仅在 postNumber == 1 时透传给 PostFooterSection
  final Widget? opTopSlot;

  const LongPostFooterSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    this.isTopicOwner = false,
    this.highlightBoostUsername,
    required this.topicHasAcceptedAnswer,
    this.acceptedAnswers = const [],
    required this.bottomDateSeparatorLabel,
    required this.onReply,
    required this.onEdit,
    required this.onShareAsImage,
    required this.onRefreshPost,
    required this.onJumpToPost,
    required this.onSolutionChanged,
    this.useReplyDialog = false,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.onShowPostDetail,
    this.opTopSlot,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final showSignatures = ref.watch(preferencesProvider).showSignatures;
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      isTopicOwner: isTopicOwner,
      eyeCareBubblePart: EyeCareBubblePart.end,
      showBottomDateSeparator: bottomDateSeparatorLabel != null,
      bottomDateSeparatorLabel: bottomDateSeparatorLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSignatures &&
              post.signatureCooked != null &&
              post.signatureCooked!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.3,
                      ),
                      width: 0.5,
                    ),
                  ),
                ),
                child: CollapsedHtmlContent(
                  html: post.signatureCooked!,
                  textStyle: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                    fontSize: 12,
                    height: 1.4,
                  ),
                  maxLines: 2,
                ),
              ),
            ),
          SelectionContainer.disabled(
            child: PostFooterSection(
              post: post,
              topicId: topicId,
              topicHasAcceptedAnswer: topicHasAcceptedAnswer,
              acceptedAnswers: acceptedAnswers,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              highlightBoostUsername: highlightBoostUsername,
              onReply: onReply,
              onEdit: onEdit,
              onShareAsImage: onShareAsImage,
              onRefreshPost: onRefreshPost,
              onJumpToPost: onJumpToPost,
              onSolutionChanged: onSolutionChanged,
              useReplyDialog: useReplyDialog,
              topicTitle: topicTitle,
              isPrivateMessageTopic: isPrivateMessageTopic,
              isPmWithNonHumanUser: isPmWithNonHumanUser,
              onShowPostDetail: onShowPostDetail,
              opTopSlot: opTopSlot,
            ),
          ),
        ],
      ),
    );
  }
}
