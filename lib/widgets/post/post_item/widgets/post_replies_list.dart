import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../common/smart_avatar.dart';

/// 回复列表组件:竖线串起各条回复的头像挂在父帖下,末端是收起按钮
class PostRepliesList extends StatelessWidget {
  static const double _avatarRadius = 14;
  static const double _replyHorizontalPadding = 4;

  /// 竖线中心与头像中心对齐
  static const double _railCenter = _replyHorizontalPadding + _avatarRadius;
  static const double _railWidth = 1.5;
  static const double _collapseButtonSize = 32;

  final List<Post> replies;
  final bool canLoadMore;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onLoadMore;
  final void Function(int postNumber)? onJumpToPost;
  final double contentFontScale;

  const PostRepliesList({
    super.key,
    required this.replies,
    required this.canLoadMore,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onLoadMore,
    this.onJumpToPost,
    this.contentFontScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (replies.isEmpty) {
      return const SizedBox.shrink();
    }

    final railColor = theme.colorScheme.outlineVariant;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Stack(
        children: [
          // 竖线穿过头像中心,止于底部收起按钮
          PositionedDirectional(
            start: _railCenter - _railWidth / 2,
            top: 0,
            bottom: _collapseButtonSize,
            child: ColoredBox(
              color: railColor,
              child: const SizedBox(width: _railWidth),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...replies.map((reply) => _buildReply(context, theme, reply)),
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: _railCenter - _collapseButtonSize / 2,
                ),
                child: Row(
                  children: [
                    _buildCollapseButton(context, theme, railColor),
                    if (canLoadMore) ...[
                      const SizedBox(width: 8),
                      ValueListenableBuilder<bool>(
                        valueListenable: isLoadingRepliesNotifier,
                        builder: (context, isLoadingReplies, _) {
                          return TextButton.icon(
                            onPressed: isLoadingReplies ? null : onLoadMore,
                            icon: isLoadingReplies
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Symbols.refresh_rounded, size: 16),
                            label: Text(context.l10n.post_loadMoreReplies),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCollapseButton(
    BuildContext context,
    ThemeData theme,
    Color borderColor,
  ) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(8),
      side: BorderSide(color: borderColor),
    );
    return Tooltip(
      message: context.l10n.post_collapseReplies,
      child: Material(
        color: Colors.transparent,
        shape: shape,
        child: InkWell(
          onTap: () => showRepliesNotifier.value = false,
          customBorder: shape,
          child: SizedBox.square(
            dimension: _collapseButtonSize,
            child: Icon(
              Symbols.expand_less_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReply(BuildContext context, ThemeData theme, Post reply) {
    final avatarUrl = reply.getAvatarUrl(size: 60);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onJumpToPost?.call(reply.postNumber),
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _replyHorizontalPadding,
            vertical: 8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SmartAvatar(
                imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                radius: _avatarRadius,
                backgroundColor: theme.colorScheme.primaryContainer,
                fallbackText: reply.username,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            (reply.name != null && reply.name!.isNotEmpty)
                                ? reply.name!
                                : reply.username,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '#${reply.postNumber}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    IgnorePointer(
                      // 回复预览:改用自研 FluxdoRender 只读渲染(关闭选区)
                      child:
                          FluxdoRenderCallbacks.generic(
                            heroTagNamespace:
                                'reply_preview_${reply.postNumber}',
                          ).render(
                            cookedHtml: reply.cooked,
                            baseTextStyle: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13 * contentFontScale,
                              height: 1.4,
                            ),
                            compact: true,
                            selectionEnabled: false,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
