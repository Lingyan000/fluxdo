import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../../services/highlighter_service.dart';
import '../../../../../services/toast_service.dart';
import '../../../../../utils/link_launcher.dart';
import 'onebox_base.dart';
import '../../../../../l10n/s.dart';

/// GitHub Onebox 构建器
class GithubOneboxBuilder {
  /// 构建 GitHub 仓库卡片
  static Widget buildRepo({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);

    // 提取仓库信息
    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final repoName = titleLink?.text ?? '';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    // 提取 GitHub 统计行
    final statsRow = element.querySelector('.github-row');
    final stats = _extractGithubStats(statsRow);

    // 提取缩略图/头像
    final imgElement = element.querySelector('img.thumbnail') ??
        element.querySelector('img');
    final imageUrl = imgElement?.attributes['src'] ?? '';

    // 提取语言信息
    final languageElement = element.querySelector('.repo-language');
    final language = languageElement?.text?.trim() ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像/缩略图
          if (imageUrl.isNotEmpty) ...[
            OneboxAvatar(
              imageUrl: imageUrl,
              size: 48,
              borderRadius: 8,
              fallbackIcon: Icons.folder,
            ),
            const SizedBox(width: 12),
          ],
          // 仓库信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 仓库名称（带 GitHub 图标）
                Row(
                  children: [
                    const Icon(Icons.code, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        repoName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.primary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 点击数
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
                // 统计和语言
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    if (language.isNotEmpty)
                      OneboxStatItem(
                        icon: Icons.circle,
                        iconSize: 10,
                        iconColor: _getLanguageColor(language),
                        value: language,
                      ),
                    if (stats.stars != null)
                      OneboxStatItem(
                        icon: Icons.star_outline,
                        value: stats.stars!,
                        iconColor: const Color(0xFFf1c40f),
                      ),
                    if (stats.forks != null)
                      OneboxStatItem(
                        icon: Icons.call_split,
                        value: stats.forks!,
                      ),
                    if (stats.watchers != null)
                      OneboxStatItem(
                        icon: Icons.visibility_outlined,
                        value: stats.watchers!,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建 GitHub 代码文件卡片
  static Widget buildBlob({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    try {
      final url = extractUrl(element);
      final isDark = theme.brightness == Brightness.dark;

      // 提取文件信息 - 可能是 h3 或 h4
      final titleElement = element.querySelector('h4') ?? element.querySelector('h3');
      final titleLink = titleElement?.querySelector('a');

      // 提取点击数
      final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

      final fileName = titleLink?.text?.trim() ?? '';

      // 如果没有文件名，使用简化展示
      if (fileName.isEmpty) {
        return _buildSimpleBlobCard(
          context: context,
          theme: theme,
          element: element,
          url: url,
          linkCounts: linkCounts,
        );
      }

      // 提取分支信息
      final branchInfo = element.querySelector('.git-blob-info');
      final branchCode = branchInfo?.querySelector('code');
      final branch = branchCode?.text?.trim() ?? '';

      // 提取代码预览 - 获取纯文本内容
      final preElement = element.querySelector('pre');
      final codeElement = preElement?.querySelector('code') ?? preElement;
      final codeText = codeElement?.text?.trim() ?? '';

      // 从文件名检测语言
      final language = _detectLanguageFromFileName(fileName);

      final bgColor =
          isDark ? const Color(0xff282a36) : const Color(0xfff6f8fa);
      final borderColor =
          theme.colorScheme.outlineVariant.withValues(alpha: 0.3);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: bgColor,
          border: Border.all(color: borderColor),
        ),
        child: InkWell(
          onTap: () => _launchUrl(context, url),
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 文件头
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.03),
                  border: Border(bottom: BorderSide(color: borderColor)),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(7)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.description_outlined, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fileName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.primary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (branch.isNotEmpty)
                            Row(
                              children: [
                                Icon(
                                  Icons.call_split,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  branch,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontFamily: 'monospace',
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    // 点击数
                    if (clickCount != null && clickCount.isNotEmpty) ...[
                      OneboxClickCount(count: clickCount),
                      const SizedBox(width: 8),
                    ],
                    // 复制按钮
                    if (codeText.isNotEmpty)
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: codeText));
                          ToastService.showSuccess(S.current.common_codeCopied);
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 代码预览
              if (codeText.isNotEmpty) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: _buildCodePreview(
                        codeText: codeText,
                        language: language,
                        isDark: isDark,
                      ),
                    ),
                  ),
                ),
                // 截断提示
                if (_isCodeTruncated(codeText))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: borderColor)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.open_in_new,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          S.current.github_viewFullCode,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    } catch (e) {
      // 出错时回退到简化卡片
      return _buildSimpleBlobCard(
        context: context,
        theme: theme,
        element: element,
        url: extractUrl(element),
        linkCounts: linkCounts,
      );
    }
  }

  /// 构建简化的 blob 卡片（用于回退）
  static Widget _buildSimpleBlobCard({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    required String url,
    List<LinkCount>? linkCounts,
  }) {
    // 提取标题和描述
    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final title = titleLink?.text?.trim() ?? 'GitHub File';

    final descElement = element.querySelector('p');
    final description = descElement?.text?.trim() ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (clickCount != null && clickCount.isNotEmpty)
                OneboxClickCount(count: clickCount),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  /// 安全的代码预览构建
  static Widget _buildCodePreview({
    required String codeText,
    required String? language,
    required bool isDark,
  }) {
    try {
      return HighlighterService.instance.buildHighlightView(
        codeText,
        language: language,
        isDark: isDark,
        backgroundColor: Colors.transparent,
        padding: const EdgeInsets.all(12),
      );
    } catch (e) {
      // 高亮失败时显示纯文本
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          codeText,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
      );
    }
  }

  /// 判断代码是否被截断（超过约 10 行）
  static bool _isCodeTruncated(String codeText) {
    final lineCount = '\n'.allMatches(codeText).length + 1;
    return lineCount > 10;
  }

  /// 构建 GitHub Issue 卡片
  static Widget buildIssue({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    // 检测是否为评论型 onebox
    final commentIcon = element.querySelector('.github-icon-container');
    final iconTitle = commentIcon?.attributes['title'] ?? '';
    if (iconTitle == 'Comment') {
      return buildComment(
        context: context,
        theme: theme,
        element: element,
        linkCounts: linkCounts,
      );
    }

    final url = extractUrl(element);

    // 提取标题
    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final title = titleLink?.text ?? '';

    // 提取状态
    final statusElement = element.querySelector('.issue-state') ??
        element.querySelector('.state');
    final statusText = statusElement?.text?.trim().toLowerCase() ?? '';
    final isOpen = statusText.contains('open');
    final isClosed = statusText.contains('closed');

    // 提取 Issue 编号
    final issueNumber = _extractIssueNumber(url);

    // 提取作者和日期
    final authorElement = element.querySelector('.author') ??
        element.querySelector('.user');
    final author = authorElement?.text?.trim() ?? '';

    final dateElement = element.querySelector('.created-at') ??
        element.querySelector('time');
    final date = dateElement?.text?.trim() ?? '';

    // 提取标签
    final labels = <_GithubLabel>[];
    final labelElements = element.querySelectorAll('.label');
    for (final label in labelElements) {
      final text = label.text?.trim() ?? '';
      final style = label.attributes['style'] ?? '';
      final color = _extractColorFromStyle(style);
      if (text.isNotEmpty) {
        labels.add(_GithubLabel(text, color));
      }
    }

    // 提取评论数
    final commentElement = element.querySelector('.comments');
    final comments = commentElement?.text?.trim();

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态和编号
          Row(
            children: [
              if (isOpen)
                OneboxStatusIndicator.issueOpen()
              else if (isClosed)
                OneboxStatusIndicator.issueClosed()
              else
                const OneboxStatusIndicator(
                  status: 'Issue',
                  color: Color(0xFF238636),
                  icon: Icons.circle_outlined,
                ),
              const SizedBox(width: 8),
              if (issueNumber != null)
                Text(
                  '#$issueNumber',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const Spacer(),
              if (clickCount != null && clickCount.isNotEmpty) ...[
                OneboxClickCount(count: clickCount),
                const SizedBox(width: 12),
              ],
              if (comments != null && comments.isNotEmpty)
                OneboxStatItem(
                  icon: Icons.chat_bubble_outline,
                  value: comments,
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 标题
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // 作者和日期
          if (author.isNotEmpty || date.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (author.isNotEmpty) author,
                if (date.isNotEmpty) date,
              ].join(' · '),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          // 标签
          if (labels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: labels.map((label) {
                return OneboxLabel(
                  text: label.name,
                  backgroundColor: label.color?.withValues(alpha: 0.2),
                  textColor: label.color,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  /// 构建 GitHub Pull Request 卡片
  static Widget buildPullRequest({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    // 检测是否为 PR/Issue 评论型 onebox
    final commentIcon = element.querySelector('.github-icon-container');
    final iconTitle = commentIcon?.attributes['title'] ?? '';
    if (iconTitle == 'Comment') {
      return buildComment(
        context: context,
        theme: theme,
        element: element,
        linkCounts: linkCounts,
      );
    }

    final url = extractUrl(element);

    // 提取标题
    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final title = titleLink?.text ?? '';

    // 提取状态
    final statusElement = element.querySelector('.pr-state') ??
        element.querySelector('.state');
    final statusText = statusElement?.text?.trim().toLowerCase() ?? '';
    final isOpen = statusText.contains('open');
    final isMerged = statusText.contains('merged');
    final isClosed = statusText.contains('closed') && !isMerged;

    // 提取 PR 编号
    final prNumber = _extractIssueNumber(url);

    // 提取分支信息
    final branchInfo = element.querySelector('.branch-info') ??
        element.querySelector('.base-ref');
    final branches = branchInfo?.text?.trim() ?? '';

    // 提取行数变更
    final additionsElement = element.querySelector('.additions');
    final deletionsElement = element.querySelector('.deletions');
    final additions = additionsElement?.text?.trim();
    final deletions = deletionsElement?.text?.trim();

    // 提取作者和日期
    final authorElement = element.querySelector('.author') ??
        element.querySelector('.user');
    final author = authorElement?.text?.trim() ?? '';

    final dateElement = element.querySelector('time');
    final date = dateElement?.text?.trim() ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态和编号
          Row(
            children: [
              if (isOpen)
                OneboxStatusIndicator.prOpen()
              else if (isMerged)
                OneboxStatusIndicator.prMerged()
              else if (isClosed)
                OneboxStatusIndicator.prClosed()
              else
                const OneboxStatusIndicator(
                  status: 'PR',
                  color: Color(0xFF238636),
                  icon: Icons.call_merge,
                ),
              const SizedBox(width: 8),
              if (prNumber != null)
                Text(
                  '#$prNumber',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const Spacer(),
              // 点击数
              if (clickCount != null && clickCount.isNotEmpty) ...[
                OneboxClickCount(count: clickCount),
                const SizedBox(width: 12),
              ],
              // 行数变更
              if (additions != null || deletions != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (additions != null) ...[
                      Text(
                        '+$additions',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFF238636),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (deletions != null)
                      Text(
                        '-$deletions',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFFda3633),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          // 标题
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          // 分支信息
          if (branches.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.call_split,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    branches,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          // 作者和日期
          if (author.isNotEmpty || date.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (author.isNotEmpty) author,
                if (date.isNotEmpty) date,
              ].join(' · '),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 构建 GitHub 评论卡片（PR/Issue 下的评论）
  static Widget buildComment({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    // 提取评论者信息 - h4 内第一个 a 是评论者
    final h4Element = element.querySelector('h4');
    final commentAuthorLink = h4Element?.querySelector('a');
    final authorName = commentAuthorLink?.text?.trim() ?? '';
    final authorAvatar = h4Element?.querySelector('img')?.attributes['src'] ?? '';

    // 提取 PR/Issue 标题 - h4 内最后一个 a 是标题链接
    final allLinks = h4Element?.querySelectorAll('a');
    String prTitle = '';
    if (allLinks != null && allLinks.length > 1) {
      prTitle = allLinks.last.text?.trim() ?? '';
    }

    // 提取分支信息
    final branchElements = element.querySelectorAll('.branches code');
    String branches = '';
    if (branchElements != null && branchElements.length >= 2) {
      branches = '${branchElements.first.text?.trim()} ← ${branchElements.last.text?.trim()}';
    } else if (branchElements != null && branchElements.length == 1) {
      branches = branchElements.first.text?.trim() ?? '';
    }

    // 提取评论正文
    final bodyElement = element.querySelector('.github-body-container');
    final bodyText = bodyElement?.text?.trim() ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 评论者信息
          Row(
            children: [
              if (authorAvatar.isNotEmpty) ...[
                OneboxAvatar(
                  imageUrl: authorAvatar,
                  size: 24,
                  borderRadius: 12,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: authorName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      TextSpan(
                        text: S.current.github_commentedOn,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 点击数
              if (clickCount != null && clickCount.isNotEmpty)
                OneboxClickCount(count: clickCount),
            ],
          ),
          // PR 标题
          if (prTitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              prTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.primary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // 分支信息
          if (branches.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.call_split,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    branches,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          // 评论正文
          if (bodyText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              bodyText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  /// 构建 GitHub Commit 卡片
  static Widget buildCommit({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);

    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final message = titleLink?.text ?? '';

    // 提取 commit hash
    final commitHash = _extractCommitHash(url);

    // 提取作者
    final authorElement = element.querySelector('.author') ??
        element.querySelector('.user');
    final author = authorElement?.text?.trim() ?? '';

    // 提取日期
    final dateElement = element.querySelector('time');
    final date = dateElement?.text?.trim() ?? '';

    // 提取头像
    final avatarElement = element.querySelector('img');
    final avatarUrl = avatarElement?.attributes['src'] ?? '';

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像
          if (avatarUrl.isNotEmpty) ...[
            OneboxAvatar(
              imageUrl: avatarUrl,
              size: 36,
              borderRadius: 18,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Commit 消息
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                // Hash 和作者信息
                Row(
                  children: [
                    if (commitHash != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          commitHash,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        [
                          if (author.isNotEmpty) author,
                          if (date.isNotEmpty) date,
                        ].join(' · '),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (clickCount != null && clickCount.isNotEmpty)
                      OneboxClickCount(count: clickCount),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 构建 GitHub Gist 卡片
  static Widget buildGist({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);
    final isDark = theme.brightness == Brightness.dark;

    // 提取 Gist 信息
    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final title = titleLink?.text ?? 'Gist';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    // 提取代码预览
    final codeElement = element.querySelector('pre') ?? element.querySelector('code');
    final codeText = codeElement?.text ?? '';

    final bgColor =
        isDark ? const Color(0xff282a36) : const Color(0xfff6f8fa);
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.3);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: bgColor,
        border: Border.all(color: borderColor),
      ),
      child: InkWell(
        onTap: () => _launchUrl(context, url),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.03),
                border: Border(bottom: BorderSide(color: borderColor)),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(7)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.code, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.primary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (description.isNotEmpty)
                          Text(
                            description,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (clickCount != null && clickCount.isNotEmpty)
                    OneboxClickCount(count: clickCount),
                ],
              ),
            ),
            // 代码预览
            if (codeText.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: HighlighterService.instance.buildHighlightView(
                      codeText,
                      isDark: isDark,
                      backgroundColor: Colors.transparent,
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 构建 GitHub Folder 卡片
  static Widget buildFolder({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);

    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final folderName = titleLink?.text ?? '';

    // 提取描述
    final descElement = element.querySelector('p');
    final description = descElement?.text ?? '';

    // 提取文件列表
    final fileElements = element.querySelectorAll('.github-file-item') +
        element.querySelectorAll('li');
    final files = <String>[];
    for (final file in fileElements) {
      final text = file.text?.trim();
      if (text != null && text.isNotEmpty) {
        files.add(text);
      }
    }

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 文件夹名
          Row(
            children: [
              const Icon(Icons.folder, size: 20, color: Color(0xFF54aeff)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  folderName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.primary,
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
          // 文件列表
          if (files.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...files.take(5).map((file) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: [
                      Icon(
                        file.endsWith('/') ? Icons.folder : Icons.description,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          file,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )),
            if (files.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  S.current.github_moreFiles(files.length - 5),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 构建 GitHub Actions 卡片
  static Widget buildActions({
    required BuildContext context,
    required ThemeData theme,
    required dynamic element,
    List<LinkCount>? linkCounts,
  }) {
    final url = extractUrl(element);

    // 提取 workflow 信息
    final h3Element = element.querySelector('h3') ?? element.querySelector('h4');
    final titleLink = h3Element?.querySelector('a');

    // 提取点击数
    final clickCount = extractClickCountFromOnebox(element, linkCounts: linkCounts);

    final workflowName = titleLink?.text ?? '';

    // 提取状态
    final statusElement = element.querySelector('.workflow-status') ??
        element.querySelector('.status');
    final statusText = statusElement?.text?.trim().toLowerCase() ?? '';
    final isSuccess = statusText.contains('success') || statusText.contains('completed');
    final isFailed = statusText.contains('failed') || statusText.contains('failure');
    final isRunning = statusText.contains('running') || statusText.contains('in_progress');

    // 提取运行信息
    final runInfo = element.querySelector('.run-info');
    final runDetails = runInfo?.text?.trim() ?? '';

    Color statusColor;
    IconData statusIcon;
    String statusLabel;

    if (isSuccess) {
      statusColor = const Color(0xFF238636);
      statusIcon = Icons.check_circle;
      statusLabel = 'Success';
    } else if (isFailed) {
      statusColor = const Color(0xFFda3633);
      statusIcon = Icons.cancel;
      statusLabel = 'Failed';
    } else if (isRunning) {
      statusColor = const Color(0xFFf1c40f);
      statusIcon = Icons.refresh;
      statusLabel = 'Running';
    } else {
      statusColor = theme.colorScheme.onSurfaceVariant;
      statusIcon = Icons.pending;
      statusLabel = 'Pending';
    }

    return OneboxContainer(
      onTap: () => _launchUrl(context, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态和名称
          Row(
            children: [
              Icon(statusIcon, size: 20, color: statusColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      workflowName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    OneboxLabel(
                      text: statusLabel,
                      backgroundColor: statusColor.withValues(alpha: 0.15),
                      textColor: statusColor,
                    ),
                  ],
                ),
              ),
              if (clickCount != null && clickCount.isNotEmpty)
                OneboxClickCount(count: clickCount),
            ],
          ),
          // 运行详情
          if (runDetails.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              runDetails,
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

// ============== 辅助函数和类 ==============

class _GithubStats {
  final String? stars;
  final String? forks;
  final String? watchers;
  final String? issues;

  _GithubStats({this.stars, this.forks, this.watchers, this.issues});
}

class _GithubLabel {
  final String name;
  final Color? color;

  _GithubLabel(this.name, this.color);
}

_GithubStats _extractGithubStats(dynamic statsRow) {
  if (statsRow == null) return _GithubStats();

  String? stars;
  String? forks;
  String? watchers;
  String? issues;

  // 尝试从各种可能的元素中提取数据
  final text = statsRow.text ?? '';

  // 匹配 star 数
  final starMatch = RegExp(r'(\d+[\d,]*)\s*(stars?|⭐)', caseSensitive: false).firstMatch(text);
  if (starMatch != null) stars = starMatch.group(1);

  // 匹配 fork 数
  final forkMatch = RegExp(r'(\d+[\d,]*)\s*(forks?|🍴)', caseSensitive: false).firstMatch(text);
  if (forkMatch != null) forks = forkMatch.group(1);

  // 尝试从子元素中提取
  final statElements = statsRow.querySelectorAll('.github-stat, .repo-stat, span');
  for (final stat in statElements) {
    final statText = stat.text?.trim() ?? '';
    if (statText.contains('star') || stat.querySelector('svg.octicon-star') != null) {
      final match = RegExp(r'(\d+[\d,]*)').firstMatch(statText);
      if (match != null) stars ??= match.group(1);
    }
    if (statText.contains('fork') || stat.querySelector('svg.octicon-repo-forked') != null) {
      final match = RegExp(r'(\d+[\d,]*)').firstMatch(statText);
      if (match != null) forks ??= match.group(1);
    }
  }

  return _GithubStats(stars: stars, forks: forks, watchers: watchers, issues: issues);
}

String? _extractIssueNumber(String url) {
  final match = RegExp(r'/(?:issues?|pull)/(\d+)').firstMatch(url);
  return match?.group(1);
}

String? _extractCommitHash(String url) {
  final match = RegExp(r'/commit/([a-f0-9]{7,40})').firstMatch(url);
  final hash = match?.group(1);
  return hash?.substring(0, 7);
}

Color? _extractColorFromStyle(String style) {
  final match = RegExp(r'background-color:\s*#([a-fA-F0-9]{6})').firstMatch(style);
  if (match != null) {
    final hex = match.group(1)!;
    return Color(int.parse('FF$hex', radix: 16));
  }
  return null;
}

String? _detectLanguageFromFileName(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  const languageMap = {
    'dart': 'dart',
    'js': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'jsx': 'javascript',
    'py': 'python',
    'rb': 'ruby',
    'go': 'go',
    'rs': 'rust',
    'java': 'java',
    'kt': 'kotlin',
    'swift': 'swift',
    'c': 'c',
    'cpp': 'cpp',
    'h': 'c',
    'hpp': 'cpp',
    'cs': 'csharp',
    'php': 'php',
    'html': 'html',
    'css': 'css',
    'scss': 'scss',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'xml': 'xml',
    'md': 'markdown',
    'sql': 'sql',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
  };
  return languageMap[ext];
}

Color _getLanguageColor(String language) {
  const colors = {
    'dart': Color(0xFF00B4AB),
    'javascript': Color(0xFFf1e05a),
    'typescript': Color(0xFF3178c6),
    'python': Color(0xFF3572A5),
    'ruby': Color(0xFF701516),
    'go': Color(0xFF00ADD8),
    'rust': Color(0xFFdea584),
    'java': Color(0xFFb07219),
    'kotlin': Color(0xFFA97BFF),
    'swift': Color(0xFFffac45),
    'c': Color(0xFF555555),
    'c++': Color(0xFFf34b7d),
    'c#': Color(0xFF178600),
    'php': Color(0xFF4F5D95),
    'html': Color(0xFFe34c26),
    'css': Color(0xFF563d7c),
    'shell': Color(0xFF89e051),
    'vue': Color(0xFF41b883),
    'react': Color(0xFF61dafb),
  };
  return colors[language.toLowerCase()] ?? const Color(0xFF8b8b8b);
}

Future<void> _launchUrl(BuildContext context, String url) async {
  if (url.isEmpty) return;
  await launchContentLink(context, url);
}

