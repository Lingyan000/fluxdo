import 'package:flutter/material.dart';
import '../../../../../utils/link_launcher.dart';
import '../../../../../services/discourse_cache_manager.dart';
import 'onebox_base.dart';

/// 视频 Onebox 构建器
class VideoOneboxBuilder {
  /// 构建 YouTube 视频卡片
  static Widget buildYoutube({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    // 提取标题
    final h4Element = element.querySelector('h4');
    final h3Element = element.querySelector('h3');
    final titleLink = h4Element?.querySelector('a') ?? h3Element?.querySelector('a');
    final title = titleLink?.text ?? '';

    // 提取视频 ID 和缩略图
    final videoId = _extractYoutubeVideoId(url);
    final thumbnailUrl = videoId != null
        ? 'https://img.youtube.com/vi/$videoId/hqdefault.jpg'
        : (element.querySelector('img')?.attributes['src'] ?? '');

    // 提取频道信息
    final channelElement = element.querySelector('.channel') ??
        element.querySelector('.author');
    final channel = channelElement?.text?.trim() ?? '';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    // 提取时长
    final durationElement = element.querySelector('.duration') ??
        element.querySelector('.video-duration');
    final duration = durationElement?.text?.trim() ?? '';

    // 提取观看数
    final viewsElement = element.querySelector('.views') ??
        element.querySelector('.video-views');
    final views = viewsElement?.text?.trim() ?? '';

    return OneboxContainer(
      padding: EdgeInsets.zero,
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 缩略图和播放按钮
          Stack(
            alignment: Alignment.center,
            children: [
              // 缩略图
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(7)),
                  child: thumbnailUrl.isNotEmpty
                      ? Image(
                          image: discourseImageProvider(thumbnailUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: Colors.black,
                              child: const Center(
                                child: Icon(
                                  Icons.video_library,
                                  size: 48,
                                  color: Colors.white54,
                                ),
                              ),
                            );
                          },
                        )
                      : Container(
                          color: Colors.black,
                          child: const Center(
                            child: Icon(
                              Icons.video_library,
                              size: 48,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                ),
              ),
              // 播放按钮
              Container(
                width: 60,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF0000),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              // 时长标签
              if (duration.isNotEmpty)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      duration,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // 视频信息
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 6),
                // 频道和观看数
                Row(
                  children: [
                    // YouTube 图标
                    const Icon(
                      Icons.play_circle_filled,
                      size: 16,
                      color: Color(0xFFFF0000),
                    ),
                    const SizedBox(width: 6),
                    if (channel.isNotEmpty)
                      Expanded(
                        child: Text(
                          channel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (views.isNotEmpty) ...[
                      Text(
                        views,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (clickCount != null && clickCount.isNotEmpty)
                      OneboxClickCount(count: clickCount),
                  ],
                ),
                // 描述
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
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
          ),
        ],
      ),
    );
  }

  /// 构建 Vimeo 视频卡片
  static Widget buildVimeo({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    // 提取标题
    final h4Element = element.querySelector('h4');
    final h3Element = element.querySelector('h3');
    final titleLink = h4Element?.querySelector('a') ?? h3Element?.querySelector('a');
    final title = titleLink?.text ?? '';

    // 提取缩略图
    final thumbnailElement = element.querySelector('img');
    final thumbnailUrl = thumbnailElement?.attributes['src'] ?? '';

    // 提取作者
    final authorElement = element.querySelector('.author');
    final author = authorElement?.text?.trim() ?? '';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    return OneboxContainer(
      padding: EdgeInsets.zero,
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 缩略图和播放按钮
          Stack(
            alignment: Alignment.center,
            children: [
              // 缩略图
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(7)),
                  child: thumbnailUrl.isNotEmpty
                      ? Image(
                          image: discourseImageProvider(thumbnailUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: const Color(0xFF1ab7ea),
                              child: const Center(
                                child: Icon(
                                  Icons.play_circle_outline,
                                  size: 48,
                                  color: Colors.white,
                                ),
                              ),
                            );
                          },
                        )
                      : Container(
                          color: const Color(0xFF1ab7ea),
                          child: const Center(
                            child: Icon(
                              Icons.play_circle_outline,
                              size: 48,
                              color: Colors.white,
                            ),
                          ),
                        ),
                ),
              ),
              // 播放按钮
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0xFF1ab7ea),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ],
          ),
          // 视频信息
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 6),
                // 作者
                Row(
                  children: [
                    // Vimeo 图标
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFF1ab7ea),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (author.isNotEmpty)
                      Expanded(
                        child: Text(
                          author,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (clickCount != null && clickCount.isNotEmpty)
                      OneboxClickCount(count: clickCount),
                  ],
                ),
                // 描述
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
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
          ),
        ],
      ),
    );
  }

  /// 构建 Loom 视频卡片
  static Widget buildLoom({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    // 提取标题
    final h4Element = element.querySelector('h4');
    final h3Element = element.querySelector('h3');
    final titleLink = h4Element?.querySelector('a') ?? h3Element?.querySelector('a');
    final title = titleLink?.text ?? '';

    // 提取缩略图
    final thumbnailElement = element.querySelector('img');
    final thumbnailUrl = thumbnailElement?.attributes['src'] ?? '';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    return OneboxContainer(
      padding: EdgeInsets.zero,
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 缩略图和播放按钮
          Stack(
            alignment: Alignment.center,
            children: [
              // 缩略图
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(7)),
                  child: thumbnailUrl.isNotEmpty
                      ? Image(
                          image: discourseImageProvider(thumbnailUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              color: const Color(0xFF625DF5),
                              child: const Center(
                                child: Icon(
                                  Icons.videocam,
                                  size: 48,
                                  color: Colors.white,
                                ),
                              ),
                            );
                          },
                        )
                      : Container(
                          color: const Color(0xFF625DF5),
                          child: const Center(
                            child: Icon(
                              Icons.videocam,
                              size: 48,
                              color: Colors.white,
                            ),
                          ),
                        ),
                ),
              ),
              // 播放按钮
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0xFF625DF5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ],
          ),
          // 视频信息
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Loom 标识
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF625DF5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Loom',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (clickCount != null && clickCount.isNotEmpty)
                      OneboxClickCount(count: clickCount),
                  ],
                ),
                const SizedBox(height: 8),
                // 标题
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                // 描述
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
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
          ),
        ],
      ),
    );
  }
}

// ============== 辅助函数 ==============

String? _extractYoutubeVideoId(String url) {
  // 支持多种 YouTube URL 格式
  final patterns = [
    RegExp(r'youtube\.com/watch\?v=([a-zA-Z0-9_-]+)'),
    RegExp(r'youtu\.be/([a-zA-Z0-9_-]+)'),
    RegExp(r'youtube\.com/embed/([a-zA-Z0-9_-]+)'),
    RegExp(r'youtube\.com/v/([a-zA-Z0-9_-]+)'),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

Future<void> _launchUrl(BuildContext context, String url) async {
  if (url.isEmpty) return;
  await launchContentLink(context, url);
}

