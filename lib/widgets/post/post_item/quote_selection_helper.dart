import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../services/toast_service.dart';
import '../../../utils/code_selection_context.dart';
import '../../../utils/html_text_mapper.dart';
import '../../../utils/html_to_markdown.dart';
import '../../../utils/quote_builder.dart';

typedef QuoteSelectionCallback = void Function(String selectedText, Post post);

class QuoteSelectionHelper {
  const QuoteSelectionHelper._();

  static String buildQuoteSelectionText(
    String plainText, {
    CodeSelectionContext? codeContext,
  }) {
    final normalizedText = plainText.trim();
    if (normalizedText.isEmpty) return '';

    if (codeContext != null) {
      return CodeSelectionContextTracker.instance.encodePayload(
        normalizedText,
        context: codeContext,
      );
    }

    return normalizedText;
  }

  static void copyQuoteToClipboard({
    required String selectedText,
    required Post post,
    required int topicId,
    CodeSelectionContext? fallbackCodeContext,
  }) {
    final codePayload = CodeSelectionContextTracker.instance.decodePayload(selectedText);
    final plainSelectedText = codePayload?.text ?? selectedText;
    final codeContext = codePayload?.context ?? fallbackCodeContext;
    String markdown;

    if (codeContext == null &&
        HtmlTextMapper.isFullSelection(post.cooked, plainSelectedText)) {
      // 全选整帖:直接转换完整 cooked,绕开子串反查(反查对图片等占位符
      // 文本的还原不完全可靠,失败会退化成裸文件名,见 image_context_menu
      // 那次的复制引用问题)。
      markdown = HtmlToMarkdown.convert(post.cooked);
      if (markdown.trim().isEmpty) markdown = plainSelectedText;
      final quote = QuoteBuilder.build(
        markdown: markdown,
        username: post.username,
        postNumber: post.postNumber,
        topicId: topicId,
      );
      Clipboard.setData(ClipboardData(text: quote));
      ToastService.showSuccess(S.current.common_quoteCopied);
      return;
    }

    final htmlFragment = HtmlTextMapper.extractHtml(post.cooked, plainSelectedText);
    if (htmlFragment != null) {
      markdown = HtmlToMarkdown.convert(htmlFragment);
      if (markdown.trim().isEmpty) {
        markdown = codeContext != null
            ? CodeSelectionContextTracker.instance.toMarkdown(
                plainSelectedText,
                context: codeContext,
              )
            : plainSelectedText;
      }
    } else if (codeContext != null) {
      markdown = CodeSelectionContextTracker.instance.toMarkdown(
        plainSelectedText,
        context: codeContext,
      );
    } else {
      markdown = plainSelectedText;
    }

    final quote = QuoteBuilder.build(
      markdown: markdown,
      username: post.username,
      postNumber: post.postNumber,
      topicId: topicId,
    );

    Clipboard.setData(ClipboardData(text: quote));
    ToastService.showSuccess(S.current.common_quoteCopied);
  }

  static List<ContextMenuButtonItem> buildMenuItems({
    required List<ContextMenuButtonItem> baseItems,
    required String? plainText,
    required Post? post,
    required VoidCallback hideToolbar,
    required int topicId,
    QuoteSelectionCallback? onQuoteSelection,
    CodeSelectionContext? codeContext,
  }) {
    if (onQuoteSelection == null ||
        post == null ||
        plainText == null ||
        plainText.trim().isEmpty) {
      return baseItems;
    }

    final items = List<ContextMenuButtonItem>.from(baseItems);
    items.insert(
      0,
      ContextMenuButtonItem(
        label: S.current.common_quote,
        onPressed: () {
          final quoteText = buildQuoteSelectionText(
            plainText,
            codeContext: codeContext,
          );
          if (quoteText.isNotEmpty) {
            onQuoteSelection(quoteText, post);
          }
          hideToolbar();
        },
      ),
    );
    items.insert(
      1,
      ContextMenuButtonItem(
        label: S.current.common_copyQuote,
        onPressed: () {
          copyQuoteToClipboard(
            selectedText: plainText,
            post: post,
            topicId: topicId,
            fallbackCodeContext: codeContext,
          );
          hideToolbar();
        },
      ),
    );

    return items;
  }
}
