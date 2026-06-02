import 'package:flutter/material.dart';
import '../../../../../utils/link_launcher.dart';
import 'onebox_base.dart';

/// 构建默认链接预览卡片
Widget buildDefaultOnebox({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  List<LinkCount>? linkCounts,
}) {
  // 提取点击数（支持 data-clicks 属性）
  final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

  // 提取标题
  final h4Element = element.querySelector('h4');
  final h3Element = element.querySelector('h3');
  final titleLink = h4Element?.querySelector('a') ?? h3Element?.querySelector('a');
  final title = titleLink?.text ?? h3Element?.text ?? h4Element?.text ?? '';
  // titleLink 可能为空（如 Google Play onebox 的 h3 不含 <a>），回退到 extractUrl
  final url = titleLink?.attributes['href'] ?? extractUrl(element);

  // 提取描述
  final descElement = element.querySelector('p');
  final description = descElement?.text ?? '';

  // 提取图标
  final iconElement = element.querySelector('img.site-icon');
  final iconUrl = iconElement?.attributes['src'] ?? '';

  // 提取来源
  final sourceElement = element.querySelector('.source a');
  final sourceName = sourceElement?.text ?? '';

  // 提取缩略图
  final thumbnailElement = element.querySelector('.thumbnail');
  final thumbnailUrl = thumbnailElement?.attributes['src'] ?? '';

  return OneboxContainer(
    onTap: () async {
      if (url.isNotEmpty) {
        await launchContentLink(context, url);
      }
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 来源和图标和点击数
        if (sourceName.isNotEmpty || iconUrl.isNotEmpty || clickCount != null)
          OneboxSourceHeader(
            iconUrl: iconUrl,
            sourceName: sourceName,
            clickCount: clickCount,
          ),
        if (sourceName.isNotEmpty || iconUrl.isNotEmpty || clickCount != null)
          const SizedBox(height: 8),

        // 内容区域（可能带缩略图）
        if (thumbnailUrl.isNotEmpty)
          _buildWithThumbnail(
            theme: theme,
            title: title,
            description: description,
            thumbnailUrl: thumbnailUrl,
          )
        else
          _buildWithoutThumbnail(
            theme: theme,
            title: title,
            description: description,
          ),
      ],
    ),
  );
}

Widget _buildWithThumbnail({
  required ThemeData theme,
  required String title,
  required String description,
  required String thumbnailUrl,
}) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) ...[
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
            ],
            if (description.isNotEmpty)
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: OneboxAvatar(
          imageUrl: thumbnailUrl,
          size: 80,
          borderRadius: 6,
          fallbackIcon: Icons.image,
        ),
      ),
    ],
  );
}

Widget _buildWithoutThumbnail({
  required ThemeData theme,
  required String title,
  required String description,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (title.isNotEmpty) ...[
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
      ],
      if (description.isNotEmpty)
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
    ],
  );
}
