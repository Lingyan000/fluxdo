import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../common/smart_avatar.dart';

/// 父帖预览:按时间顺序列在当前帖头部上方,竖线串起各父帖头像,
/// 经收起按钮连到当前帖头像
class PostReplyHistory extends StatelessWidget {
  static const double _avatarRadius = 14;

  /// 当前帖头像半径(PostAvatar 默认值),竖线中心与之对齐
  static const double _headerAvatarRadius = 20;
  static const double _parentHorizontalPadding =
      _headerAvatarRadius - _avatarRadius;
  static const double _parentVerticalPadding = 8;
  static const double _railWidth = 1.5;
  static const double _collapseButtonSize = 32;

  /// 收起按钮下沿到当前帖头像的竖线段
  static const double _bottomGap = 8;

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

    final railColor = theme.colorScheme.outlineVariant;
    Widget rail({double? top, double? bottom, double? height}) {
      return PositionedDirectional(
        start: _headerAvatarRadius - _railWidth / 2,
        top: top,
        bottom: bottom,
        height: height,
        child: ColoredBox(
          color: railColor,
          child: const SizedBox(width: _railWidth),
        ),
      );
    }

    return Stack(
      children: [
        // 从首个父帖头像中心到收起按钮,再从按钮下沿接到当前帖头像
        rail(
          top: _parentVerticalPadding + _avatarRadius,
          bottom: _bottomGap + _collapseButtonSize,
        ),
        rail(bottom: 0, height: _bottomGap),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...replyHistory!.map(
              (parent) => _buildParent(context, theme, parent),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: _headerAvatarRadius - _collapseButtonSize / 2,
                bottom: _bottomGap,
              ),
              child: _buildCollapseButton(context, theme, railColor),
            ),
          ],
        ),
      ],
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
      message: context.l10n.post_collapseParentPosts,
      child: Material(
        color: Colors.transparent,
        shape: shape,
        child: InkWell(
          onTap: () => showReplyHistoryNotifier.value = false,
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

  Widget _buildParent(BuildContext context, ThemeData theme, Post parent) {
    final avatarUrl = parent.getAvatarUrl(size: 60);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onJumpToPost?.call(parent.postNumber),
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _parentHorizontalPadding,
            vertical: _parentVerticalPadding,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SmartAvatar(
                imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                radius: _avatarRadius,
                backgroundColor: theme.colorScheme.primaryContainer,
                fallbackText: parent.username,
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
                            (parent.name != null && parent.name!.isNotEmpty)
                                ? parent.name!
                                : parent.username,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '#${parent.postNumber}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    IgnorePointer(
                      // 父帖可能很长:只露开头并渐隐,完整内容点击跳楼层看
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
                          constraints: const BoxConstraints(maxHeight: 60),
                          child: SingleChildScrollView(
                            physics: const NeverScrollableScrollPhysics(),
                            // 父帖预览:改用自研 FluxdoRender 只读渲染(关闭选区)
                            child:
                                FluxdoRenderCallbacks.generic(
                                  heroTagNamespace:
                                      'reply_history_${parent.postNumber}',
                                ).render(
                                  cookedHtml: parent.cooked,
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
      ),
    );
  }
}
