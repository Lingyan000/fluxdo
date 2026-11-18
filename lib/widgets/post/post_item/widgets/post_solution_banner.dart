import 'package:common_ui/common_ui.dart';
import 'package:fluxdo/utils/avatar_url.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show HtmlChunker;
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../services/preloaded_data_service.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../../utils/html_preview_truncator.dart';
import '../../../../utils/time_utils.dart';
import '../../../../utils/url_helper.dart';
import '../../../common/smart_avatar.dart';
import '../../../../theme/app_colors.dart';

/// 解决方案横幅(仅在主贴下方展示)
///
/// 渲染:
/// - 顶部绿色 header:"已解决  N 解决方案"
/// - 列表每行:头像 + 用户名 + 时间 + 展开/折叠箭头
/// - 默认第一项展开,答案正文按 `solved_quote_length` 截高预览 + "阅读更多"跳转
class PostSolutionBanner extends StatefulWidget {
  final List<AcceptedAnswer> acceptedAnswers;
  final void Function(int postNumber)? onJumpToPost;

  const PostSolutionBanner({
    super.key,
    required this.acceptedAnswers,
    this.onJumpToPost,
  });

  @override
  State<PostSolutionBanner> createState() => _PostSolutionBannerState();
}

class _PostSolutionBannerState extends State<PostSolutionBanner> {
  /// 当前展开行的索引,-1 表示全部折叠
  int _expandedIndex = 0;

  @override
  void didUpdateWidget(PostSolutionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表长度变化时,如展开项超出新列表范围,回退到默认展开第一项
    if (_expandedIndex >= widget.acceptedAnswers.length) {
      _expandedIndex = widget.acceptedAnswers.isEmpty ? -1 : 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final answers = widget.acceptedAnswers;
    if (answers.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ClipRSuperellipse(
        borderRadius: context.shapes.borderRadius(12),
        child: Container(
          decoration: ShapeDecoration(
            color: isDark
                ? context.appColors.green.withValues(alpha: 0.05)
                : context.appColors.green.withValues(alpha: 0.04),
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(12),
              side: BorderSide(
                color: context.appColors.green.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BannerHeader(count: answers.length),
              for (var i = 0; i < answers.length; i++)
                _AnswerRow(
                  key: ValueKey('accepted-answer-${answers[i].postNumber}'),
                  answer: answers[i],
                  expanded: _expandedIndex == i,
                  isLast: i == answers.length - 1,
                  onToggle: () {
                    setState(() {
                      _expandedIndex = _expandedIndex == i ? -1 : i;
                    });
                  },
                  onJumpToPost: widget.onJumpToPost,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BannerHeader extends StatelessWidget {
  final int count;
  const _BannerHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2E7D32) : const Color(0xFF43A047),
      ),
      child: Row(
        children: [
          const Icon(Symbols.check_box_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(
            context.l10n.post_topicSolved,
            style: theme.textTheme.titleSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          if (count > 1) ...[
            const SizedBox(width: 12),
            Text(
              context.l10n.post_solutionsCount(count),
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.85),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnswerRow extends StatelessWidget {
  final AcceptedAnswer answer;
  final bool expanded;
  final bool isLast;
  final VoidCallback onToggle;
  final void Function(int postNumber)? onJumpToPost;

  const _AnswerRow({
    super.key,
    required this.answer,
    required this.expanded,
    required this.isLast,
    required this.onToggle,
    required this.onJumpToPost,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = (answer.name?.isNotEmpty ?? false)
        ? answer.name!
        : answer.username;
    final timeText = TimeUtils.formatRelativeTime(answer.createdAt);
    final avatarUrl = (answer.avatarTemplate?.isNotEmpty ?? false)
        ? UrlHelper.resolveUrlWithCdn(
            AvatarUrl.resolve(answer.avatarTemplate!, size: 48),
          )
        : null;
    final hasContent = (answer.cooked?.isNotEmpty ?? false);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hasContent
                ? onToggle
                : () => onJumpToPost?.call(answer.postNumber),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  SmartAvatar(
                    imageUrl: avatarUrl,
                    radius: 12,
                    fallbackText: displayName.isNotEmpty
                        ? displayName.substring(0, 1).toUpperCase()
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (timeText.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            '·',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            timeText,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasContent)
                    Icon(
                      expanded
                          ? Symbols.expand_less_rounded
                          : Symbols.expand_more_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  else
                    Icon(
                      Symbols.arrow_forward_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (expanded && hasContent)
            _ExpandedContent(
              cooked: answer.cooked!,
              postNumber: answer.postNumber,
              onJumpToPost: onJumpToPost,
            ),
        ],
      ),
    );
  }
}

class _ExpandedContent extends StatelessWidget {
  final String cooked;
  final int postNumber;
  final void Function(int postNumber)? onJumpToPost;

  const _ExpandedContent({
    required this.cooked,
    required this.postNumber,
    required this.onJumpToPost,
  });

  /// 站点 `solved_quote_length`(默认 700 字符)
  static int _quoteLength() {
    final raw = PreloadedDataService().siteSettingsSync?['solved_quote_length'];
    final chars = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 700;
    return chars <= 0 ? 700 : chars;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 14,
      height: 1.5,
      color: theme.colorScheme.onSurface,
    );
    final lineHeight =
        (textStyle?.fontSize ?? 14) *
        (textStyle?.height ?? 1.5) *
        MediaQuery.textScalerOf(context).scale(1);
    // 预览行数按每行约 90 字符折算;只渲染开头部分,长答案不整段构建排版。
    // 文字预算留一倍余量,宽屏一行放得下更多字时也能填满预览高度
    final quoteLength = _quoteLength();
    final preview = HtmlPreviewTruncator.truncate(
      cooked,
      maxText: quoteLength * 2,
      maxMarkup: HtmlChunker.chunkThreshold,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ClampedPreview(
            maxHeight: lineHeight * (quoteLength / 90).ceil(),
            truncated: preview.truncated,
            // 解决方案正文:自研 FluxdoRender 只读预览(非正文场景关闭选区)
            child:
                FluxdoRenderCallbacks.generic(
                  heroTagNamespace: 'solution_excerpt_$postNumber',
                ).render(
                  cookedHtml: preview.html,
                  baseTextStyle: textStyle,
                  compact: true,
                  selectionEnabled: false,
                ),
          ),
          const SizedBox(height: 6),
          InkWell(
            onTap: () => onJumpToPost?.call(postNumber),
            customBorder: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Text(
                context.l10n.post_readMore,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 限高预览:内容超出 [maxHeight] 或已被截断时底部渐隐,否则原样展示
class _ClampedPreview extends StatefulWidget {
  final double maxHeight;
  final bool truncated;
  final Widget child;

  const _ClampedPreview({
    required this.maxHeight,
    required this.truncated,
    required this.child,
  });

  @override
  State<_ClampedPreview> createState() => _ClampedPreviewState();
}

class _ClampedPreviewState extends State<_ClampedPreview> {
  final _controller = ScrollController();
  // 渐隐层切换时保住内容子树,避免正文重建与滚动控制器重新挂载
  final _contentKey = GlobalKey();
  bool _overflowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _checkOverflow() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final overflowing = position.maxScrollExtent > 0.5;
    if (overflowing != _overflowing) setState(() => _overflowing = overflowing);
  }

  @override
  Widget build(BuildContext context) {
    // 图片等异步加载会改变内容高度,随滚动度量变化重新判定
    Widget content = NotificationListener<ScrollMetricsNotification>(
      key: _contentKey,
      onNotification: (_) {
        _checkOverflow();
        return false;
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: SingleChildScrollView(
          controller: _controller,
          physics: const NeverScrollableScrollPhysics(),
          child: widget.child,
        ),
      ),
    );
    if (_overflowing || widget.truncated) {
      content = ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black, Colors.transparent],
          stops: [0.75, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: content,
      );
    }
    return content;
  }
}
