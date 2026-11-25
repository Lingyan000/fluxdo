import 'package:flutter/foundation.dart' show immutable;
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../models/topic.dart';
import '../../widgets/post/post_item/render_parse_cache.dart';
import '../../widgets/post/post_item/segmented_long_post.dart';

/// 首贴沉浸阅读列表中的单个渲染项。
@immutable
sealed class ReaderListItem {
  const ReaderListItem({required this.itemKey});

  /// 供虚拟列表稳定保位与跳转使用的唯一键。
  final String itemKey;
}

/// 书页头部：话题标题、作者、发布时间与预计阅读时长。
class ReaderHeaderItem extends ReaderListItem {
  const ReaderHeaderItem({
    required this.title,
    required this.authorName,
    required this.createdAt,
    required this.estimatedWordCount,
  }) : super(itemKey: 'reader_header');

  final String title;
  final String authorName;
  final DateTime? createdAt;
  final int estimatedWordCount;
}

/// 短首贴正文（整段走 [FluxdoRender] 渲染）。
class ReaderPostShortItem extends ReaderListItem {
  const ReaderPostShortItem({
    required super.itemKey,
    required this.post,
    required this.preprocessedHtml,
    required this.parsedNodes,
  });

  final Post post;
  final String preprocessedHtml;
  final List<BlockNode> parsedNodes;
}

/// 长首贴的单个分块（共享 [NewEngineLongPostData] 与锚点注册表）。
class ReaderPostChunkItem extends ReaderListItem {
  const ReaderPostChunkItem({
    required super.itemKey,
    required this.post,
    required this.longData,
    required this.chunkIndex,
  });

  final Post post;
  final NewEngineLongPostData longData;
  final int chunkIndex;
}

/// 文末区：完结提示与返回讨论入口。
class ReaderFooterItem extends ReaderListItem {
  const ReaderFooterItem({required this.replyCount})
    : super(itemKey: 'reader_footer');

  final int replyCount;
}

/// 目录标题条目（仅来自首贴真实书写的 HTML 原生标题 `h1`–`h5`）。
@immutable
class ReaderHeading {
  const ReaderHeading({
    required this.id,
    required this.title,
    required this.level,
    required this.itemKey,
    required this.anchorKey,
  });

  final String id;
  final String title;

  /// 标题级别（1..5）。
  final int level;

  /// 对应的 [ReaderListItem.itemKey]（用于粗定位）。
  final String itemKey;

  /// 用于 [HeadingAnchorRegistry] 精确对齐的锚点键。
  final String anchorKey;
}

/// 首贴沉浸阅读文档视图产物。
@immutable
class ReaderDocument {
  const ReaderDocument({
    required this.items,
    required this.headings,
    required this.estimatedWordCount,
    required this.itemIndexByKey,
  });

  final List<ReaderListItem> items;
  final List<ReaderHeading> headings;
  final int estimatedWordCount;
  final Map<String, int> itemIndexByKey;

  bool get hasHeadings => headings.isNotEmpty;
}

/// 首贴沉浸阅读文档构建器：将 1 楼正文拆分为可虚拟化渲染的段落项与原生 HTML 标题目录。
abstract final class ReaderDocumentBuilder {
  static ReaderDocument build({
    required int topicId,
    required String title,
    required String authorName,
    required DateTime? topicCreatedAt,
    required Post firstPost,
    required int replyCount,
  }) {
    final longData = NewEngineLongPostData.tryBuild(
      firstPost,
      topicId: topicId,
    );

    final items = <ReaderListItem>[];
    final headings = <ReaderHeading>[];
    late final int wordCount;

    if (longData != null) {
      final chunkNodes = <List<BlockNode>>[
        for (var i = 0; i < longData.chunks.length; i++)
          longData.parsedChunkAt(i),
      ];
      wordCount = chunkNodes.fold<int>(
        0,
        (sum, nodes) => sum + _countChars(nodes),
      );
      final toc = TocExtractor.buildFromChunks(
        chunkNodes,
        postId: firstPost.id,
        minHeadings: 1,
      );
      final tocFlat = toc?.flat ?? const <TocEntry>[];

      items.add(
        ReaderHeaderItem(
          title: title,
          authorName: authorName,
          createdAt: topicCreatedAt ?? firstPost.createdAt,
          estimatedWordCount: wordCount,
        ),
      );
      for (var ci = 0; ci < longData.chunks.length; ci++) {
        final chunkKey = 'reader_post_${firstPost.id}_chunk_$ci';
        items.add(
          ReaderPostChunkItem(
            itemKey: chunkKey,
            post: firstPost,
            longData: longData,
            chunkIndex: ci,
          ),
        );
        for (final h in tocFlat.where((e) => e.chunkIndex == ci)) {
          headings.add(
            ReaderHeading(
              id: 'h_${firstPost.id}_${h.id}',
              title: h.text,
              level: h.level,
              itemKey: chunkKey,
              anchorKey: h.anchorKey,
            ),
          );
        }
      }
    } else {
      final parsed = RenderParseCache.shortPost(firstPost);
      wordCount = _countChars(parsed.nodes);
      final toc = TocExtractor.build(
        parsed.nodes,
        postId: firstPost.id,
        minHeadings: 1,
      );
      final postKey = 'reader_post_${firstPost.id}';
      items.add(
        ReaderHeaderItem(
          title: title,
          authorName: authorName,
          createdAt: topicCreatedAt ?? firstPost.createdAt,
          estimatedWordCount: wordCount,
        ),
      );
      items.add(
        ReaderPostShortItem(
          itemKey: postKey,
          post: firstPost,
          preprocessedHtml: parsed.preprocessed,
          parsedNodes: parsed.nodes,
        ),
      );
      for (final h in toc?.flat ?? const <TocEntry>[]) {
        headings.add(
          ReaderHeading(
            id: 'h_${firstPost.id}_${h.id}',
            title: h.text,
            level: h.level,
            itemKey: postKey,
            anchorKey: h.anchorKey,
          ),
        );
      }
    }

    items.add(ReaderFooterItem(replyCount: replyCount.clamp(0, 999999)));

    final itemIndexByKey = <String, int>{
      for (var i = 0; i < items.length; i++) items[i].itemKey: i,
    };

    return ReaderDocument(
      items: List<ReaderListItem>.unmodifiable(items),
      headings: List<ReaderHeading>.unmodifiable(headings),
      estimatedWordCount: wordCount,
      itemIndexByKey: itemIndexByKey,
    );
  }

  /// 计算阅读进度（0.0..1.0），供极简页眉与位置持久化复用。
  static double computeProgress({
    required double pixels,
    required double maxScrollExtent,
  }) {
    if (maxScrollExtent <= 0) return 1.0;
    return (pixels / maxScrollExtent).clamp(0.0, 1.0);
  }

  static int _countChars(List<BlockNode> nodes) {
    var count = 0;
    for (final block in nodes) {
      switch (block) {
        case ParagraphNode(:final inlines):
          count += TocExtractor.plainTextOfInlines(inlines).trim().length;
        case HeadingNode(:final inlines):
          count += TocExtractor.plainTextOfInlines(inlines).trim().length;
        case ListNode(:final items):
          for (final item in items) {
            if (item.blocks != null) {
              count += _countChars(item.blocks!);
            } else {
              count += TocExtractor.plainTextOfInlines(
                item.inlines,
              ).trim().length;
              if (item.children != null) {
                count += _countChars(item.children!);
              }
            }
          }
        case BlockquoteNode(:final children):
          count += _countChars(children);
        case CodeBlockNode(:final code):
          count += code.length;
        default:
          break;
      }
    }
    return count;
  }
}
