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

    // extractHtml 内置全选快路径:选中内容等于整帖时直接返回完整 cooked。
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
      displayName: post.name,
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
