import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../../../utils/link_launcher.dart';
import '../iframe_builder.dart';
import 'onebox_base.dart';

/// Spotify Onebox 构建器
///
/// Discourse 的 Spotify onebox 返回 `<aside class="onebox spotify-onebox">`
/// 内含 `<iframe>`（Spotify 内嵌播放器），需要直接渲染 iframe。
class SpotifyOneboxBuilder {
  /// 构建 Spotify 播放器卡片
  static Widget buildSpotify({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    // 提取 iframe 子元素
    final iframeEl = element.querySelector('iframe');
    if (iframeEl != null) {
      final attrs = IframeAttributes.fromElement(iframeEl);
      // Spotify iframe 通常需要 allow-scripts + allow-same-origin
      // 确保 WebView 能正常加载播放器
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: IframeWidget(attributes: attrs),
        ),
      );
    }

    // 没有 iframe 时回退到默认卡片
    return _buildFallback(context, theme, element, linkCounts);
  }

  /// 回退：显示默认 onebox 卡片
  static Widget _buildFallback(
    BuildContext context,
    ThemeData theme,
    dynamic element,
    List<LinkCount>? linkCounts,
  ) {
    final url = extractUrl(element);
    final clickCount = extractClickCountFromOnebox(
      element,
      linkCounts: linkCounts,
    );

    // 提取标题
    final h4Element = element.querySelector('h4');
    final h3Element = element.querySelector('h3');
    final titleLink =
        h4Element?.querySelector('a') ?? h3Element?.querySelector('a');
    final title = titleLink?.text ?? '';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    // 提取缩略图
    final thumbnail = element.querySelector('img')?.attributes['src'] ?? '';

    return OneboxContainer(
      onTap: () async {
        if (url.isNotEmpty) {
          await launchContentLink(context, url);
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部：Spotify 品牌
          Row(
            children: [
              Icon(
                Symbols.music_note_rounded,
                size: 18,
                color: const Color(0xFF1DB954),
              ),
              const SizedBox(width: 6),
              Text(
                'Spotify',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF1DB954),
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (clickCount != null && clickCount.isNotEmpty) ...[
                const Spacer(),
                OneboxClickCount(count: clickCount),
              ],
            ],
          ),
          if (thumbnail.isNotEmpty) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image(
                image: NetworkImage(thumbnail),
                fit: BoxFit.cover,
                height: 120,
                width: double.infinity,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              ),
            ),
          ],
          if (title.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
