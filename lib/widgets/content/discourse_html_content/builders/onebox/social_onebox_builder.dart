import 'package:flutter/material.dart';
import '../../../../../utils/link_launcher.dart';
import 'onebox_base.dart';

/// 社交媒体 Onebox 构建器
class SocialOneboxBuilder {
  /// 构建 Twitter 推文卡片
  static Widget buildTwitter({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    // 提取用户信息
    final displayName = element.querySelector('.display-name')?.text?.trim() ??
        element.querySelector('h4')?.text?.trim() ??
        '';
    final username = element.querySelector('.screen-name')?.text?.trim() ??
        element.querySelector('.username')?.text?.trim() ??
        _extractTwitterUsername(url);

    // 提取头像
    final avatarElement = element.querySelector('img.twitter-avatar') ??
        element.querySelector('img');
    final avatarUrl = avatarElement?.attributes['src'] ?? '';

    // 提取推文内容
    final contentElement = element.querySelector('.tweet-content') ??
        element.querySelector('.tweet') ??
        element.querySelector('blockquote') ??
        element.querySelector('p');
    final content = contentElement?.text?.trim() ?? '';

    // 提取时间
    final timeElement = element.querySelector('time') ??
        element.querySelector('.tweet-date');
    final time = timeElement?.text?.trim() ?? '';

    // 提取统计
    final likesElement = element.querySelector('.likes') ??
        element.querySelector('.favorite-count');
    final retweetsElement = element.querySelector('.retweets') ??
        element.querySelector('.retweet-count');
    final likes = likesElement?.text?.trim();
    final retweets = retweetsElement?.text?.trim();

    // 提取图片
    final imageElements = element.querySelectorAll('.tweet-image img') +
        element.querySelectorAll('.media img');
    final images = imageElements
        .map((img) => img.attributes['src'] as String?)
        .where((src) => src != null && src.isNotEmpty)
        .toList();

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用户信息头部
          Row(
            children: [
              // 头像
              OneboxAvatar(
                imageUrl: avatarUrl,
                size: 40,
                borderRadius: 20,
              ),
              const SizedBox(width: 10),
              // 用户名
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (displayName.isNotEmpty)
                      Text(
                        displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (username.isNotEmpty)
                      Text(
                        username.startsWith('@') ? username : '@$username',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              // X 平台标识
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    '𝕏',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.brightness == Brightness.dark
                          ? Colors.black
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // 推文内容
          if (content.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              content,
              style: theme.textTheme.bodyMedium,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // 图片预览
          if (images.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: OneboxAvatar(
                imageUrl: images.first,
                size: 150,
                borderRadius: 8,
                fallbackIcon: Icons.image,
              ),
            ),
          ],
          // 时间和统计
          const SizedBox(height: 10),
          Row(
            children: [
              if (time.isNotEmpty)
                Text(
                  time,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const Spacer(),
              if (clickCount != null && clickCount.isNotEmpty) ...[
                OneboxClickCount(count: clickCount),
                const SizedBox(width: 12),
              ],
              if (retweets != null && retweets.isNotEmpty)
                OneboxStatItem(
                  icon: Icons.repeat,
                  value: retweets,
                  iconColor: const Color(0xFF00ba7c),
                ),
              if (retweets != null && likes != null) const SizedBox(width: 12),
              if (likes != null && likes.isNotEmpty)
                OneboxStatItem(
                  icon: Icons.favorite_outline,
                  value: likes,
                  iconColor: const Color(0xFFf91880),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建 Reddit 帖子卡片
  static Widget buildReddit({
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

    // 提取子版块
    final subredditElement = element.querySelector('.subreddit') ??
        element.querySelector('.reddit-subreddit');
    final subreddit = subredditElement?.text?.trim() ??
        _extractSubreddit(url);

    // 提取作者
    final authorElement = element.querySelector('.author') ??
        element.querySelector('.reddit-author');
    final author = authorElement?.text?.trim() ?? '';

    // 提取内容摘要
    final contentElement = element.querySelector('.reddit-content') ??
        element.querySelector('p');
    final content = contentElement?.text?.trim() ?? '';

    // 提取统计
    final scoreElement = element.querySelector('.score') ??
        element.querySelector('.reddit-score');
    final commentsElement = element.querySelector('.comments') ??
        element.querySelector('.reddit-comments');
    final score = scoreElement?.text?.trim();
    final comments = commentsElement?.text?.trim();

    // 提取缩略图
    final thumbnailElement = element.querySelector('.thumbnail') ??
        element.querySelector('img');
    final thumbnailUrl = thumbnailElement?.attributes['src'] ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 子版块和作者
          Row(
            children: [
              // Reddit 图标
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF4500),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.reddit,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (subreddit.isNotEmpty)
                      Text(
                        subreddit.startsWith('r/') ? subreddit : 'r/$subreddit',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (author.isNotEmpty)
                      Text(
                        author.startsWith('u/') ? author : 'u/$author',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 标题
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (thumbnailUrl.isNotEmpty &&
                  !thumbnailUrl.contains('self') &&
                  !thumbnailUrl.contains('default')) ...[
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: OneboxAvatar(
                    imageUrl: thumbnailUrl,
                    size: 70,
                    borderRadius: 6,
                    fallbackIcon: Icons.image,
                  ),
                ),
              ],
            ],
          ),
          // 内容摘要
          if (content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              content,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // 统计
          const SizedBox(height: 8),
          Row(
            children: [
              if (score != null && score.isNotEmpty)
                OneboxStatItem(
                  icon: Icons.arrow_upward,
                  value: score,
                  iconColor: const Color(0xFFFF4500),
                ),
              if (score != null && comments != null) const SizedBox(width: 16),
              if (comments != null && comments.isNotEmpty)
                OneboxStatItem(
                  icon: Icons.chat_bubble_outline,
                  value: comments,
                ),
              const Spacer(),
              if (clickCount != null && clickCount.isNotEmpty)
                OneboxClickCount(count: clickCount),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建 Instagram 卡片
  static Widget buildInstagram({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    // 提取用户名
    final usernameElement = element.querySelector('.instagram-username') ??
        element.querySelector('.author');
    final username = usernameElement?.text?.trim() ?? '';

    // 提取描述
    final captionElement = element.querySelector('.instagram-caption') ??
        element.querySelector('p');
    final caption = captionElement?.text?.trim() ?? '';

    // 提取图片
    final imageElement = element.querySelector('img');
    final imageUrl = imageElement?.attributes['src'] ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用户头部
          Row(
            children: [
              // Instagram 渐变图标
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFF833AB4),
                      Color(0xFFE1306C),
                      Color(0xFFF77737),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.camera_alt,
                  size: 18,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  username.startsWith('@') ? username : '@$username',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          // 图片
          if (imageUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 1,
                child: OneboxAvatar(
                  imageUrl: imageUrl,
                  size: double.infinity,
                  borderRadius: 8,
                  fallbackIcon: Icons.image,
                ),
              ),
            ),
          ],
          // 描述
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // 点击数
          if (clickCount != null && clickCount.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OneboxClickCount(count: clickCount),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ============== 辅助函数 ==============

String _extractTwitterUsername(String url) {
  final match = RegExp(r'(?:twitter\.com|x\.com)/(\w+)').firstMatch(url);
  return match?.group(1) ?? '';
}

String _extractSubreddit(String url) {
  final match = RegExp(r'reddit\.com/r/(\w+)').firstMatch(url);
  return match?.group(1) ?? '';
}

Future<void> _launchUrl(BuildContext context, String url) async {
  if (url.isEmpty) return;
  await launchContentLink(context, url);
}

