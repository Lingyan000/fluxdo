import 'package:flutter/material.dart';
import 'package:popover/popover.dart';
import '../discourse_html_content_widget.dart';

/// 构建脚注引用（上标数字链接）
Widget buildFootnoteRef({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required String fullHtml,
  List<String>? galleryImages,
}) {
  // 获取脚注链接
  final aElement = element.querySelector('a');
  final href = aElement?.attributes['href'] as String? ?? '';
  // 获取脚注编号文本（可能是 "1" 或 "[1]"）
  var footnoteText = aElement?.text ?? '';
  // 如果已经有方括号，不重复添加
  if (!footnoteText.startsWith('[')) {
    footnoteText = '[$footnoteText]';
  }
  
  // 从完整 HTML 中提取脚注内容
  String? footnoteContent;
  if (href.startsWith('#')) {
    final footnoteId = href.substring(1);
    final escapedId = RegExp.escape(footnoteId);
    final footnoteRegex = RegExp(
      '<li[^>]*id=["\']?$escapedId["\']?[^>]*>([\\s\\S]*?)</li>',
      caseSensitive: false,
    );
    final match = footnoteRegex.firstMatch(fullHtml);
    if (match != null) {
      footnoteContent = match.group(1)?.replaceAll(
        RegExp(r'<a[^>]*class="[^"]*footnote-backref[^"]*"[^>]*>[\s\S]*?</a>', caseSensitive: false),
        '',
      ).trim();
      if (footnoteContent != null) {
        footnoteContent = footnoteContent
            .replaceAll(RegExp(r'^<p>\s*'), '')
            .replaceAll(RegExp(r'\s*</p>$'), '')
            .trim();
      }
    }
  }

  return _FootnoteRefWidget(
    footnoteText: footnoteText,
    footnoteContent: footnoteContent,
    galleryImages: galleryImages,
  );
}

/// 脚注引用 Widget
class _FootnoteRefWidget extends StatelessWidget {
  final String footnoteText;
  final String? footnoteContent;
  final List<String>? galleryImages;

  const _FootnoteRefWidget({
    required this.footnoteText,
    this.footnoteContent,
    this.galleryImages,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return GestureDetector(
      onTap: () {
        if (footnoteContent != null && footnoteContent!.isNotEmpty) {
          showPopover(
            context: context,
            bodyBuilder: (context) => _FootnotePopoverContent(
              content: footnoteContent!,
              galleryImages: galleryImages,
            ),
            direction: PopoverDirection.bottom,
            arrowHeight: 8,
            arrowWidth: 12,
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            barrierColor: Colors.transparent,
            radius: 8,
            shadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          );
        }
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Transform.translate(
          offset: const Offset(0, -3),
          child: Text(
            footnoteText,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 脚注内容弹窗
class _FootnotePopoverContent extends StatelessWidget {
  final String content;
  final List<String>? galleryImages;

  const _FootnotePopoverContent({
    required this.content,
    this.galleryImages,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.3,
        maxWidth: screenWidth * 0.85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: DiscourseHtmlContent(
          html: content,
          compact: true,
          galleryImages: galleryImages,
          textStyle: theme.textTheme.bodyMedium?.copyWith(
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// 构建脚注列表区域（隐藏）
Widget buildFootnotesList({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Widget Function(String, TextStyle?) htmlBuilder,
}) {
  return const SizedBox.shrink();
}

/// 构建脚注分隔线（隐藏）
Widget buildFootnotesSep() {
  return const SizedBox.shrink();
}
