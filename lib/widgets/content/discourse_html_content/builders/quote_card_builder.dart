import 'package:flutter/material.dart';
import '../../../common/smart_avatar.dart';
import '../../../../l10n/s.dart';

/// 构建回复引用卡片
Widget buildQuoteCard({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Widget Function(String html, TextStyle? textStyle) htmlBuilder,
}) {
  final username = element.attributes['data-username'] ?? S.current.common_quote;
  final imgElement = element.querySelector('img.avatar');
  final avatarUrl = imgElement?.attributes['src'] ?? '';
    final titleElement = element.querySelector('.quote-title__text-content');
  String? titleHtml;
  String? categoryHtml;
  if (titleElement != null) {
    final categoryElement =
        titleElement.querySelector('.badge-category__wrapper');
    if (categoryElement != null) {
      categoryHtml = categoryElement.outerHtml;
      categoryElement.remove();
    }
    final trimmedTitle = titleElement.innerHtml.trim();
    if (trimmedTitle.isNotEmpty) {
      titleHtml = trimmedTitle;
    }
  } else {
    // 兼容旧版 Discourse 格式：标题链接直接在 .title 下
    final titleDiv = element.querySelector('.title');
    if (titleDiv != null) {
      final titleLink = titleDiv.querySelector('a');
      if (titleLink != null) {
        titleHtml = titleLink.outerHtml;
      }
    }
  }

  final blockquoteElement = element.querySelector('blockquote');
  final quoteContent = blockquoteElement?.innerHtml ?? '';

  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      border: Border(
        left: BorderSide(
          color: theme.colorScheme.outline,
          width: 4,
        ),
      ),
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(4),
        bottomRight: Radius.circular(4),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 引用头部：头像 + 用户名 + 标题 + 分类
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              if (avatarUrl.isNotEmpty) ...[
                SmartAvatar(
                  imageUrl: avatarUrl,
                  radius: 12,
                  fallbackText: username,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Row(
                  children: [
                    Text(
                      '$username:',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (titleHtml != null) ...[
                      const SizedBox(width: 4),
                      Expanded(
                        child: htmlBuilder(
                          '<div style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">$titleHtml</div>',
                          theme.textTheme.labelMedium?.copyWith(
                            height: 1.2,
                            color: theme.colorScheme.primary,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    if (categoryHtml != null) ...[
                      const SizedBox(width: 4),
                      htmlBuilder(
                        categoryHtml,
                        theme.textTheme.labelMedium?.copyWith(
                          height: 1.2,
                          fontSize: 11, // 分类稍微小一点
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // 引用内容
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: htmlBuilder(
            quoteContent,
            theme.textTheme.bodyMedium?.copyWith(
              height: 1.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}
