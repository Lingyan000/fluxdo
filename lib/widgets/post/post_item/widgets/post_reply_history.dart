import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../common/smart_avatar.dart';

/// 回复历史预览组件
class PostReplyHistory extends StatelessWidget {
  final List<Post>? replyHistory;
  final ValueNotifier<bool> showReplyHistoryNotifier;
  final void Function(int postNumber)? onJumpToPost;
  final double contentFontScale;

  const PostReplyHistory({
    super.key,
    required this.replyHistory,
    required this.showReplyHistoryNotifier,
    this.onJumpToPost,
    this.contentFontScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (replyHistory == null || replyHistory!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(12),
          side: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Area
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Icon(
                  Symbols.format_quote_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  context.l10n.post_replyTo,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    showReplyHistoryNotifier.value = false;
                  },
                  customBorder: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Symbols.close_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 0.5,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
          // Reply Items
          ...replyHistory!.map((replyPost) {
            final avatarUrl = replyPost.getAvatarUrl(size: 60);
            return InkWell(
              onTap: () => onJumpToPost?.call(replyPost.postNumber),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SmartAvatar(
                      imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                      radius: 14,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      fallbackText: replyPost.username,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                (replyPost.name != null &&
                                        replyPost.name!.isNotEmpty)
                                    ? replyPost.name!
                                    : replyPost.username,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '#${replyPost.postNumber}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                Symbols.arrow_outward_rounded,
                                size: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          IgnorePointer(
                            child: ShaderMask(
                              shaderCallback: (rect) {
                                return const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Colors.black, Colors.transparent],
                                  stops: [0.6, 1.0],
                                ).createShader(rect);
                              },
                              blendMode: BlendMode.dstIn,
                              child: Container(
                                constraints: const BoxConstraints(
                                  maxHeight: 60,
                                ),
                                child: SingleChildScrollView(
                                  physics: const NeverScrollableScrollPhysics(),
                                  // 回复历史预览:改用自研 FluxdoRender 只读渲染(关闭选区)
                                  child:
                                      FluxdoRenderCallbacks.generic(
                                        heroTagNamespace:
                                            'reply_history_${replyPost.postNumber}',
                                      ).render(
                                        cookedHtml: replyPost.cooked,
                                        baseTextStyle: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 13 * contentFontScale,
                                              height: 1.4,
                                            ),
                                        compact: true,
                                        selectionEnabled: false,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
