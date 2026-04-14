import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/topic.dart';
import '../../../pages/topic_detail_page/topic_detail_page.dart';
import '../../../providers/preferences_provider.dart';
import '../../content/discourse_html_content/chunked/chunked_html_content.dart';
import '../../content/discourse_html_content/chunked/html_chunk.dart';
import '../../content/discourse_html_content/image_utils.dart';
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
    final chunks = ChunkedHtmlContent.getChunks(html) ?? const <HtmlChunk>[];
    if (chunks.isEmpty) {
      return LongPostRenderData(
        chunks: chunks,
        galleryImages: const <String>[],
        spoilerImageUrls: <String>{},
      );
    }

    final galleryInfo = GalleryInfo.fromHtml(html);
    return LongPostRenderData(
      chunks: chunks,
      galleryImages: galleryInfo.images,
      spoilerImageUrls: galleryInfo.spoilerImageUrls,
    );
  }
}

class LongPostHeaderSegment extends StatelessWidget {
  final Post post;
  final int topicId;
  final bool highlight;
  final bool isTopicOwner;
  final String? dateSeparatorLabel;
  final bool showDivider;
  final void Function(int postNumber)? onJumpToPost;

  const LongPostHeaderSegment({
    super.key,
    required this.post,
    required this.topicId,
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
      highlight: highlight,
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
  final bool highlight;
  final HtmlChunk chunk;
  final LongPostRenderData renderData;
  final void Function(String quote, Post post)? onQuoteImage;

  const LongPostChunkSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.highlight,
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
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) *
          ref.watch(preferencesProvider).contentFontScale,
    );

    return PostSegmentFrame(
      post: post,
      highlight: highlight,
      showBottomBorder: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          decoration: isModeratorAction
              ? BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          padding: isModeratorAction ? const EdgeInsets.all(12) : EdgeInsets.zero,
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

class LongPostFooterSegment extends StatelessWidget {
  final Post post;
  final int topicId;
  final bool highlight;
  final bool topicHasAcceptedAnswer;
  final int? acceptedAnswerPostNumber;
  final String? bottomDateSeparatorLabel;
  final VoidCallback? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onShareAsImage;
  final void Function(int postId)? onRefreshPost;
  final void Function(int postNumber)? onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool useReplyDialog;
  final VoidCallback? onShowPostDetail;
  final String? highlightBoostUsername;

  const LongPostFooterSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.highlight,
    this.highlightBoostUsername,
    required this.topicHasAcceptedAnswer,
    required this.acceptedAnswerPostNumber,
    required this.bottomDateSeparatorLabel,
    required this.onReply,
    required this.onEdit,
    required this.onShareAsImage,
    required this.onRefreshPost,
    required this.onJumpToPost,
    required this.onSolutionChanged,
    this.useReplyDialog = false,
    this.onShowPostDetail,
  });

  @override
  Widget build(BuildContext context) {
    return PostSegmentFrame(
      post: post,
      highlight: highlight,
      showBottomDateSeparator: bottomDateSeparatorLabel != null,
      bottomDateSeparatorLabel: bottomDateSeparatorLabel,
      child: SelectionContainer.disabled(
        child: PostFooterSection(
          post: post,
          topicId: topicId,
          topicHasAcceptedAnswer: topicHasAcceptedAnswer,
          acceptedAnswerPostNumber: acceptedAnswerPostNumber,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          highlightBoostUsername: highlightBoostUsername,
          onReply: onReply,
          onEdit: onEdit,
          onShareAsImage: onShareAsImage,
          onRefreshPost: onRefreshPost,
          onJumpToPost: onJumpToPost,
          onSolutionChanged: onSolutionChanged,
          useReplyDialog: useReplyDialog,
          onShowPostDetail: onShowPostDetail,
        ),
      ),
    );
  }
}
