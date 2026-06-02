import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/topic.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/share_utils.dart';
import '../../utils/url_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../common/loading_spinner.dart';
import '../common/relative_time_text.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/number_utils.dart';
import '../common/emoji_text.dart';
import '../common/smart_avatar.dart';
import '../common/topic_badges.dart';
import '../content/discourse_html_content/discourse_html_content.dart';
import '../../pages/category_topics_page.dart';
import '../../pages/tag_topics_page.dart';
import '../../../../../l10n/s.dart';

/// 预览弹窗中的操作项
class PreviewAction {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const PreviewAction({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}

/// 话题预览弹窗 - 长按卡片时显示
class TopicPreviewDialog extends ConsumerStatefulWidget {
  final Topic topic;
  final VoidCallback? onOpen;
  final List<PreviewAction>? actions;
  final WidgetBuilder? customActionPanelBuilder;
  final Future<String?> Function()? firstPostLoader;

  const TopicPreviewDialog({
    super.key,
    required this.topic,
    this.onOpen,
    this.actions,
    this.customActionPanelBuilder,
    this.firstPostLoader,
  });

  @override
  ConsumerState<TopicPreviewDialog> createState() => _TopicPreviewDialogState();

  /// 显示预览弹窗
  static Future<void> show(
    BuildContext context, {
    required Topic topic,
    VoidCallback? onOpen,
    List<PreviewAction>? actions,
    WidgetBuilder? customActionPanelBuilder,
    Future<String?> Function()? firstPostLoader,
  }) {
    // 触觉反馈
    HapticFeedback.mediumImpact();

    return showAppGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: S.current.common_closePreview,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) {
        return TopicPreviewDialog(
          topic: topic,
          onOpen: onOpen,
          actions: actions,
          customActionPanelBuilder: customActionPanelBuilder,
          firstPostLoader: firstPostLoader,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return ScaleTransition(
          scale: curvedAnimation,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
    );
  }
}

class _TopicPreviewDialogState extends ConsumerState<TopicPreviewDialog> {
  String? _firstPostCooked;
  bool _isLoading = true;
  bool _loadFailed = false;

  Topic get topic => widget.topic;

  @override
  void initState() {
    super.initState();
    _loadFirstPost();
  }

  Future<void> _loadFirstPost() async {
    try {
      final cooked = widget.firstPostLoader != null
          ? await widget.firstPostLoader!()
          : await ref
                .read(discourseServiceProvider)
                .getTopicFirstPostCooked(topic.id);
      if (!mounted) return;
      setState(() {
        _firstPostCooked = cooked;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final maxWidth = screenSize.width * 0.9;
    final maxHeight = screenSize.height * 0.7;

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final categoryId = int.tryParse(topic.categoryId);
    final category = categoryMap?[categoryId];

    // 图标逻辑
    FaIconData? faIcon = FontAwesomeHelper.getIcon(category?.icon);
    String? logoUrl = category?.uploadedLogo;

    if (faIcon == null &&
        (logoUrl == null || logoUrl.isEmpty) &&
        category?.parentCategoryId != null) {
      final parent = categoryMap?[category!.parentCategoryId];
      faIcon = FontAwesomeHelper.getIcon(parent?.icon);
      logoUrl = parent?.uploadedLogo;
    }

    final hasActions = widget.actions != null && widget.actions!.isNotEmpty;
    final hasCustomActionPanel = widget.customActionPanelBuilder != null;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.clamp(300, 500),
          maxHeight: maxHeight,
        ),
        child: SizedBox(
          key: const ValueKey('topic-preview-root'),
          height: maxHeight,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              Expanded(
                child: Material(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  elevation: 8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              theme.colorScheme.primaryContainer,
                              theme.colorScheme.tertiaryContainer,
                            ],
                          ),
                        ),
                      ),
                      if (hasCustomActionPanel)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: widget.customActionPanelBuilder!(context),
                        ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(
                            20,
                            hasCustomActionPanel ? 16 : 20,
                            20,
                            20,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTitle(context, theme),
                              const SizedBox(height: 12),
                              _buildAuthorInfo(context, theme),
                              if (category != null ||
                                  topic.tags.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                _buildCategoryAndTags(
                                  context,
                                  theme,
                                  category,
                                  faIcon,
                                  logoUrl,
                                ),
                              ],
                              const SizedBox(height: 16),
                              _buildPostContent(context, theme),
                              const SizedBox(height: 16),
                              if (topic.posters.length > 1)
                                _buildParticipants(context, theme),
                              _buildStats(context, theme),
                            ],
                          ),
                        ),
                      ),
                      _buildActions(context, theme),
                    ],
                  ),
                ),
              ),
              if (hasActions) ...[
                const SizedBox(height: 8),
                _buildCustomActions(context, theme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPostContent(BuildContext context, ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: LoadingSpinner(size: 24),
        ),
      );
    }

    if (_firstPostCooked != null &&
        _firstPostCooked!.isNotEmpty &&
        !_loadFailed) {
      // 加载成功：渲染主贴 HTML
      final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
      return DiscourseHtmlContent(
        html: _firstPostCooked!,
        compact: true,
        textStyle: theme.textTheme.bodyMedium?.copyWith(
          height: 1.5,
          fontSize:
              (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
        ),
        onInternalLinkTap: (topicId, topicSlug, postNumber) {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TopicDetailPage(
                topicId: topicId,
                initialTitle: topicSlug,
                scrollToPostNumber: postNumber,
              ),
            ),
          );
        },
      );
    }

    // 加载失败：降级展示 excerpt
    if (topic.excerpt != null && topic.excerpt!.isNotEmpty) {
      return _buildExcerptFallback(theme);
    }

    return const SizedBox.shrink();
  }

  Widget _buildExcerptFallback(ThemeData theme) {
    final cleanExcerpt = topic.excerpt!
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();

    if (cleanExcerpt.isEmpty) return const SizedBox.shrink();

    final contentFontScale = ref.watch(preferencesProvider).contentFontScale;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        cleanExcerpt,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.6,
          fontSize:
              (theme.textTheme.bodyMedium?.fontSize ?? 14) * contentFontScale,
        ),
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildTitle(BuildContext context, ThemeData theme) {
    return Text.rich(
      TextSpan(
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        children: [
          if (topic.closed)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.lock_outline,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (topic.pinned)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          if (topic.hasAcceptedAnswer)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.check_box, size: 20, color: Colors.green),
              ),
            ),
          ...EmojiText.buildEmojiSpans(
            context,
            topic.title,
            theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthorInfo(BuildContext context, ThemeData theme) {
    String? avatarUrl;
    String username;

    if (topic.posters.isNotEmpty && topic.posters.first.user != null) {
      final op = topic.posters.first.user!;
      avatarUrl = op.getAvatarUrl(size: 56);
      username = op.username;
    } else {
      username = topic.lastPosterUsername ?? '';
    }

    return Row(
      children: [
        SmartAvatar(imageUrl: avatarUrl, radius: 14, fallbackText: username),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            username,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (topic.createdAt != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '·',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          RelativeTimeText(
            dateTime: topic.createdAt,
            displayStyle: TimeDisplayStyle.prefixed,
            prefix: S.current.topic_createdAt,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCategoryAndTags(
    BuildContext context,
    ThemeData theme,
    Category? category,
    FaIconData? faIcon,
    String? logoUrl,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 分类
        if (category != null)
          GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CategoryTopicsPage(category: category),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _parseColor(category.color).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _parseColor(category.color).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (faIcon != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FaIcon(
                        faIcon,
                        size: 12,
                        color: _parseColor(category.color),
                      ),
                    )
                  else if (logoUrl != null && logoUrl.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Image(
                        image: discourseImageProvider(
                          UrlHelper.resolveUrlWithCdn(logoUrl),
                        ),
                        width: 12,
                        height: 12,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildCategoryDot(category);
                        },
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _buildCategoryDot(category),
                    ),
                  Text(
                    category.name,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 标签
        ...topic.tags.map(
          (tag) => TagBadge(
            name: tag.name,
            size: const BadgeSize(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              radius: 8,
              iconSize: 12,
              fontSize: 13,
            ),
            textStyle: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TagTopicsPage(tagName: tag.name),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildParticipants(BuildContext context, ThemeData theme) {
    final participants = topic.posters.take(5).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Text(
            S.current.topic_participants,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 28,
              child: Stack(
                children: List.generate(participants.length, (index) {
                  final poster = participants[index];
                  String? avatarUrl;
                  String fallback = '';

                  if (poster.user != null) {
                    avatarUrl = poster.user!.getAvatarUrl(size: 56);
                    fallback = poster.user!.username;
                  }

                  return Positioned(
                    left: index * 20.0,
                    child: SmartAvatar(
                      imageUrl: avatarUrl,
                      radius: 14,
                      fallbackText: fallback,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(BuildContext context, ThemeData theme) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStatItem(
                context,
                Icons.chat_bubble_outline_rounded,
                S.current.topic_replyCount(
                  (topic.postsCount - 1).clamp(0, 999999),
                ),
              ),
            ),
            Expanded(
              child: _buildStatItem(
                context,
                Icons.favorite_border_rounded,
                S.current.topic_likeCount(
                  NumberUtils.formatCount(topic.likeCount),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildStatItem(
                context,
                Icons.visibility_outlined,
                S.current.topic_viewCount(NumberUtils.formatCount(topic.views)),
              ),
            ),
            Expanded(
              child: _buildStatWidgetItem(
                context,
                Icons.access_time,
                RelativeTimeText(
                  dateTime: topic.lastPostedAt,
                  displayStyle: TimeDisplayStyle.prefixed,
                  prefix: S.current.topic_lastReply,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatWidgetItem(
    BuildContext context,
    IconData icon,
    Widget child,
  ) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        child,
      ],
    );
  }

  Widget _buildStatItem(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          // 关闭按钮
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(S.current.common_close),
          ),

          const Spacer(),

          // 分享按钮
          IconButton(
            onPressed: () {
              final user = ref.read(currentUserProvider).value;
              final prefs = ref.read(preferencesProvider);
              final url = ShareUtils.buildShareUrl(
                path: '/t/topic/${topic.id}',
                username: user?.username,
                anonymousShare: prefs.anonymousShare,
              );
              SharePlus.instance.share(ShareParams(text: url));
            },
            icon: const Icon(Icons.share_outlined, size: 20),
            tooltip: S.current.common_share,
          ),

          const SizedBox(width: 8),

          // 打开按钮
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onOpen?.call();
            },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(S.current.common_viewDetails),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomActions(BuildContext context, ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: widget.actions!.asMap().entries.map((entry) {
          final index = entry.key;
          final action = entry.value;
          final color = action.color ?? theme.colorScheme.onSurface;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  action.onTap();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(action.icon, size: 20, color: color),
                      const SizedBox(width: 12),
                      Text(
                        action.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
