import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../models/topic.dart';
import 'onebox/onebox_type.dart';
import 'onebox/default_onebox_builder.dart';
import 'onebox/user_onebox_builder.dart';
import 'onebox/github_onebox_builder.dart';
import 'onebox/social_onebox_builder.dart';
import 'onebox/video_onebox_builder.dart';
import 'onebox/tech_onebox_builder.dart';
import 'onebox/spotify_onebox_builder.dart';
import '../../../../l10n/s.dart';

/// 构建链接预览卡片 (onebox)
///
/// 这是 onebox 卡片的主入口，根据检测到的类型路由到对应的专用 builder
Widget buildOneboxCard({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  List<LinkCount>? linkCounts,
}) {
  try {
    // 检测 onebox 类型
    final type = detectOneboxType(element);

    // 根据类型路由到对应的 builder
    return _buildByType(
      context: context,
      theme: theme,
      element: element,
      type: type,
      linkCounts: linkCounts,
    );
  } catch (e, stackTrace) {
    debugPrint('=== Onebox Error ===\nError: $e\nStackTrace: $stackTrace');
    // 出错时回退到默认样式
    return _buildSafeDefault(
      context: context,
      theme: theme,
      element: element,
      linkCounts: linkCounts,
    );
  }
}

/// 根据类型构建对应的 onebox
Widget _buildByType({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required OneboxType type,
  List<LinkCount>? linkCounts,
}) {
  try {
    switch (type) {
      // 用户卡片
      case OneboxType.userOnebox:
        return buildUserOnebox(
          context: context,
          theme: theme,
          element: element,
        );

      // GitHub 系列
      case OneboxType.githubRepo:
        return GithubOneboxBuilder.buildRepo(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubBlob:
        return GithubOneboxBuilder.buildBlob(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubIssue:
        return GithubOneboxBuilder.buildIssue(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubPullRequest:
        return GithubOneboxBuilder.buildPullRequest(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubCommit:
        return GithubOneboxBuilder.buildCommit(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubGist:
        return GithubOneboxBuilder.buildGist(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubFolder:
        return GithubOneboxBuilder.buildFolder(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.githubActions:
        return GithubOneboxBuilder.buildActions(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );

      // 社交媒体
      case OneboxType.twitterStatus:
        return SocialOneboxBuilder.buildTwitter(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.reddit:
        return SocialOneboxBuilder.buildReddit(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.instagram:
        return SocialOneboxBuilder.buildInstagram(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );

      // 视频平台
      case OneboxType.youtube:
        return VideoOneboxBuilder.buildYoutube(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.vimeo:
        return VideoOneboxBuilder.buildVimeo(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.loom:
        return VideoOneboxBuilder.buildLoom(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );

      // 技术平台
      case OneboxType.stackExchange:
        return TechOneboxBuilder.buildStackExchange(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.hackernews:
        return TechOneboxBuilder.buildHackernews(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
      case OneboxType.pastebin:
        return TechOneboxBuilder.buildPastebin(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );

      // 音频
      case OneboxType.spotify:
        return SpotifyOneboxBuilder.buildSpotify(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );

      // 暂未实现专用样式的类型，使用默认样式
      case OneboxType.threads:
      case OneboxType.tiktok:
      case OneboxType.googleDocs:
      case OneboxType.pdf:
      case OneboxType.amazon:
      case OneboxType.discourseTopic:
      case OneboxType.defaultOnebox:
        return buildDefaultOnebox(
          context: context,
          theme: theme,
          element: element,
          linkCounts: linkCounts,
        );
    }
  } catch (e, stackTrace) {
    debugPrint(
      '=== Onebox Build Error [$type] ===\nError: $e\nStackTrace: $stackTrace',
    );
    // 专用 builder 失败时回退到默认样式
    return _buildSafeDefault(
      context: context,
      theme: theme,
      element: element,
      linkCounts: linkCounts,
    );
  }
}

/// 安全的默认构建（最后的回退）
Widget _buildSafeDefault({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  List<LinkCount>? linkCounts,
}) {
  try {
    return buildDefaultOnebox(
      context: context,
      theme: theme,
      element: element,
      linkCounts: linkCounts,
    );
  } catch (e) {
    // 连默认样式都失败了，返回一个最简单的占位
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Symbols.link_rounded, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              S.current.onebox_linkPreview,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
