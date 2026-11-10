import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../services/discourse_cache_manager.dart';
import '../../../../utils/link_launcher.dart';
import 'iframe_builder.dart';
import 'onebox/onebox_base.dart';

/// 从 HTML element 提取懒加载视频属性
class _LazyVideoAttributes {
  final String provider;
  final String videoId;
  final String title;
  final String thumbnailUrl;
  final String startTime;
  final String url;

  _LazyVideoAttributes({
    required this.provider,
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.startTime,
    required this.url,
  });

  /// 构建嵌入 iframe URL（与 Discourse lazy-iframe 组件一致）
  String get embedUrl {
    switch (provider) {
      case 'youtube':
        final buffer = StringBuffer(
          'https://www.youtube.com/embed/$videoId?autoplay=1&rel=0',
        );
        if (startTime.isNotEmpty) {
          final seconds = _convertToSeconds(startTime);
          if (seconds > 0) buffer.write('&start=$seconds');
        }
        return buffer.toString();
      case 'vimeo':
        final separator = videoId.contains('?') ? '&' : '?';
        return 'https://player.vimeo.com/video/$videoId${separator}autoplay=1';
      case 'tiktok':
        return 'https://www.tiktok.com/embed/v2/$videoId';
      default:
        return '';
    }
  }

  /// 品牌色
  Color get brandColor => switch (provider) {
    'youtube' => const Color(0xFFFF0000),
    'vimeo' => const Color(0xFF1ab7ea),
    'tiktok' => const Color(0xFF010101),
    _ => const Color(0xFF666666),
  };

  /// 将 "1h30m45s" 格式的时间转换为秒数
  static int _convertToSeconds(String time) {
    final match = RegExp(r'(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?').firstMatch(time);
    if (match == null) return int.tryParse(time) ?? 0;
    final h = int.tryParse(match.group(1) ?? '') ?? 0;
    final m = int.tryParse(match.group(2) ?? '') ?? 0;
    final s = int.tryParse(match.group(3) ?? '') ?? 0;
    if (h == 0 && m == 0 && s == 0) return int.tryParse(time) ?? 0;
    return h * 3600 + m * 60 + s;
  }
}

/// 构建 Discourse 懒加载视频 Widget (div.lazy-video-container)
///
/// 行为与 Discourse 网页端一致：
/// 1. 初始显示缩略图 + 播放按钮 + 标题
/// 2. 点击后原地替换为 WebView iframe 播放视频
Widget? buildLazyVideo({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  List<LinkCount>? linkCounts,
}) {
  final attrs = element.attributes;
  final provider = (attrs['data-provider-name'] as String?) ?? '';
  final videoId = (attrs['data-video-id'] as String?) ?? '';

  if (videoId.isEmpty) return null;

  final title = (attrs['data-video-title'] as String?) ?? '';
  final startTime = (attrs['data-video-start-time'] as String?) ?? '';

  // 提取缩略图
  final imgElement = element.querySelector('img');
  final thumbnailUrl = (imgElement?.attributes['src'] as String?) ?? '';

  // 提取链接 URL
  final titleLink =
      element.querySelector('a.title-link') ?? element.querySelector('a');
  final url = (titleLink?.attributes['href'] as String?) ?? '';

  final videoAttrs = _LazyVideoAttributes(
    provider: provider,
    videoId: videoId,
    title: title,
    thumbnailUrl: thumbnailUrl,
    startTime: startTime,
    url: url,
  );

  // 提取点击数
  String? clickCount;
  if (linkCounts != null) {
    final titleLink = element.querySelector('a');
    final url = titleLink?.attributes['href'] as String? ?? '';
    if (url.isNotEmpty) {
      clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);
    }
  }

  return _LazyVideoWidget(videoAttrs: videoAttrs, clickCount: clickCount);
}

/// 懒加载视频 StatefulWidget：缩略图 ↔ iframe 切换
class _LazyVideoWidget extends StatefulWidget {
  final _LazyVideoAttributes videoAttrs;
  final String? clickCount;

  const _LazyVideoWidget({required this.videoAttrs, this.clickCount});

  @override
  State<_LazyVideoWidget> createState() => _LazyVideoWidgetState();
}

class _LazyVideoWidgetState extends State<_LazyVideoWidget> {
  bool _isLoaded = false;

  void _loadEmbed() {
    if (!_isLoaded) {
      setState(() => _isLoaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attrs = widget.videoAttrs;

    if (_isLoaded) {
      return _buildIframe(attrs);
    }

    return _buildThumbnail(theme, attrs);
  }

  /// 阶段 1：缩略图卡片
  Widget _buildThumbnail(ThemeData theme, _LazyVideoAttributes attrs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRSuperellipse(
        borderRadius: context.shapes.borderRadius(8),
        child: Container(
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 缩略图 + 播放按钮
              GestureDetector(
                onTap: _loadEmbed,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: attrs.thumbnailUrl.isNotEmpty
                          ? Image(
                              image: discourseImageProvider(attrs.thumbnailUrl),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Container(
                                    color: Colors.black,
                                    child: const Center(
                                      child: Icon(
                                        Symbols.video_library_rounded,
                                        size: 48,
                                        color: Colors.white54,
                                      ),
                                    ),
                                  ),
                            )
                          : const Center(
                              child: Icon(
                                Symbols.video_library_rounded,
                                size: 48,
                                color: Colors.white54,
                              ),
                            ),
                    ),
                    // 播放按钮
                    Container(
                      width: 60,
                      height: 42,
                      decoration: ShapeDecoration(
                        color: attrs.brandColor.withValues(alpha: 0.9),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: context.shapes.borderRadius(8),
                        ),
                      ),
                      child: const Icon(
                        Symbols.play_arrow_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ],
                ),
              ),
              // 标题栏（点击打开视频链接）
              if (attrs.title.isNotEmpty)
                GestureDetector(
                  onTap: attrs.url.isNotEmpty
                      ? () => launchContentLink(context, attrs.url)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            attrs.title,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: attrs.url.isNotEmpty
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.clickCount != null) ...[
                          const SizedBox(width: 8),
                          OneboxClickCount(count: widget.clickCount!),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 阶段 2：嵌入 iframe 播放器
  Widget _buildIframe(_LazyVideoAttributes attrs) {
    final embedUrl = attrs.embedUrl;
    if (embedUrl.isEmpty) return const SizedBox.shrink();

    // 复用 IframeWidget 渲染 WebView
    final iframeAttrs = IframeAttributes(
      src: embedUrl,
      allowFullscreen: true,
      allow: {
        'accelerometer',
        'autoplay',
        'encrypted-media',
        'gyroscope',
        'picture-in-picture',
      },
      title: attrs.title,
      classes: {'${attrs.provider}-onebox'},
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRSuperellipse(
          borderRadius: context.shapes.borderRadius(8),
          child: IframeWidget(attributes: iframeAttrs),
        ),
      ),
    );
  }
}
