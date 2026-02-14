import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../constants.dart';
import '../../models/topic.dart';
import '../../utils/time_utils.dart';
import '../common/smart_avatar.dart';
import '../common/flair_badge.dart';
import '../common/emoji_text.dart';
import '../content/discourse_html_content/discourse_html_content_widget.dart';
import 'share_image_preview.dart';

/// 分享图片 Widget
/// 用于生成可截图的分享图片
class ShareImageWidget extends ConsumerWidget {
  /// 话题详情
  final TopicDetail detail;

  /// 帖子（如果为 null，则显示主帖）
  final Post? post;

  /// 用于截图的 key
  final GlobalKey repaintBoundaryKey;

  /// 分享图片主题
  final ShareImageTheme shareTheme;

  const ShareImageWidget({
    super.key,
    required this.detail,
    this.post,
    required this.repaintBoundaryKey,
    required this.shareTheme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = shareTheme.isDark;
    final bgColor = shareTheme.bgColor;
    final cardColor = shareTheme.cardColor;

    // 根据主题计算文字颜色
    final textColor = isDark ? Colors.white : Colors.black;
    final secondaryTextColor = isDark
        ? Colors.white.withValues(alpha: 0.6)
        : Colors.black.withValues(alpha: 0.6);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.1);

    // 优先使用传入的 post，否则查找主帖，最后使用第一个可用帖子
    final targetPost = post
        ?? detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull
        ?? detail.postStream.posts.firstOrNull;

    if (targetPost == null) {
      return RepaintBoundary(
        key: repaintBoundaryKey,
        child: Container(
          width: 375,
          padding: const EdgeInsets.all(40),
          color: bgColor,
          child: Center(
            child: Text('暂无内容', style: TextStyle(color: textColor)),
          ),
        ),
      );
    }

    return RepaintBoundary(
      key: repaintBoundaryKey,
      child: Container(
        width: 375,
        padding: const EdgeInsets.all(20),
        color: bgColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Logo
            _buildLogo(textColor),
            const SizedBox(height: 16),

            // 标题
            _buildTitle(context, textColor),
            const SizedBox(height: 12),

            // 作者信息
            _buildAuthorInfo(context, targetPost, textColor, secondaryTextColor, borderColor),
            const SizedBox(height: 12),

            // 分隔线
            Container(height: 1, color: borderColor),
            const SizedBox(height: 12),

            // 内容
            _buildContent(context, targetPost, cardColor, textColor),

            const SizedBox(height: 16),

            // 分隔线
            Container(height: 1, color: borderColor),
            const SizedBox(height: 12),

            // 底部分享链接
            _buildShareLink(targetPost, secondaryTextColor),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo(Color textColor) {
    return Row(
      children: [
        SvgPicture.asset(
          'assets/logo.svg',
          width: 28,
          height: 28,
        ),
        const SizedBox(width: 8),
        Text(
          'LINUX DO',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: textColor.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  Widget _buildTitle(BuildContext context, Color textColor) {
    final titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: textColor.withValues(alpha: 0.9),
      height: 1.4,
    );

    return Text.rich(
      TextSpan(
        style: titleStyle, // 设置父 TextSpan 的默认样式
        children: EmojiText.buildEmojiSpans(
          context,
          detail.title,
          titleStyle,
        ),
      ),
    );
  }

  Widget _buildAuthorInfo(BuildContext context, Post post, Color textColor, Color secondaryTextColor, Color borderColor) {
    final fullAvatarUrl = post.getAvatarUrl(size: 120);

    return Row(
      children: [
        AvatarWithFlair(
          flairSize: 14,
          flairRight: -3,
          flairBottom: -1,
          flairUrl: post.flairUrl,
          flairName: post.flairName,
          flairBgColor: post.flairBgColor,
          flairColor: post.flairColor,
          avatar: SmartAvatar(
            imageUrl: fullAvatarUrl,
            radius: 18,
            fallbackText: post.username,
            backgroundColor: Colors.grey.shade300,
            border: Border.all(color: borderColor, width: 1),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                post.name?.isNotEmpty == true ? post.name! : post.username,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor.withValues(alpha: 0.85),
                ),
              ),
              Text(
                '@${post.username} · ${TimeUtils.formatRelativeTime(post.createdAt)}',
                style: TextStyle(
                  fontSize: 12,
                  color: secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, Post post, Color cardColor, Color textColor) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DiscourseHtmlContent(
        html: post.cooked,
        textStyle: TextStyle(
          fontSize: 14,
          height: 1.6,
          color: textColor.withValues(alpha: 0.85),
        ),
        compact: false,
        enableSelectionArea: false,
        enablePanguSpacing: false,
        screenshotMode: true,
      ),
    );
  }

  Widget _buildShareLink(Post post, Color secondaryTextColor) {
    final url = '${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}/${post.postNumber}';

    return Row(
      children: [
        Icon(
          Icons.link,
          size: 14,
          color: secondaryTextColor,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            url,
            style: TextStyle(
              fontSize: 11,
              color: secondaryTextColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

}
