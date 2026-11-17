import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../common/smart_avatar.dart';

const double _embeddedFontSize = 13;
const double _embeddedLineHeight = 1.4;

String _displayName(Post post) =>
    (post.name != null && post.name!.isNotEmpty) ? post.name! : post.username;

Widget _renderCooked(
  BuildContext context, {
  required Post post,
  required String heroTagNamespace,
  required double contentFontScale,
  Color? color,
}) {
  return IgnorePointer(
    // 嵌入帖预览:自研 FluxdoRender 只读渲染(关闭选区)
    child: FluxdoRenderCallbacks.generic(heroTagNamespace: heroTagNamespace)
        .render(
          cookedHtml: post.cooked,
          baseTextStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: _embeddedFontSize * contentFontScale,
            height: _embeddedLineHeight,
            color: color,
          ),
          compact: true,
          selectionEnabled: false,
        ),
  );
}

/// 父帖引用卡:与正文里的引用块(aside.quote)同一套样式——左侧竖条、
/// 浅底、头像 + 用户名,点击跳到该楼层。父帖是当前帖的上文,按引用
/// 呈现,不缩进、不缩小成子级的样子。
///
/// 超长正文收起时只露开头 [foldedLines] 行并渐隐,下方给展开/收起;
/// 展开状态由调用方持有([unfolded]/[onToggleUnfold]),随快照保留。
class ParentPostQuoteCard extends StatelessWidget {
  final Post post;
  final double contentFontScale;
  final VoidCallback? onTap;
  final int foldedLines;
  final bool unfolded;
  final VoidCallback onToggleUnfold;

  const ParentPostQuoteCard({
    super.key,
    required this.post,
    required this.onToggleUnfold,
    this.contentFontScale = 1.0,
    this.onTap,
    this.foldedLines = 3,
    this.unfolded = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final renderStyle = FluxdoRenderStyle.of(theme);
    final avatarUrl = post.getAvatarUrl(size: 48);
    final borderRadius = BorderRadiusDirectional.horizontal(
      end: context.shapes.radius(4),
    ).resolve(Directionality.of(context));

    return ClipRSuperellipse(
      borderRadius: borderRadius,
      child: Material(
        color: renderStyle.quoteBackground
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.3)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: BorderDirectional(
                start: BorderSide(
                  color: scheme.outline,
                  width: renderStyle.quoteBarWidth,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SmartAvatar(
                        imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                        radius: 12,
                        backgroundColor: scheme.primaryContainer,
                        fallbackText: post.username,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _displayName(post),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '#${post.postNumber}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _FoldableContent(
                    foldedLines: foldedLines,
                    unfolded: unfolded,
                    onToggleUnfold: onToggleUnfold,
                    fontSize: _embeddedFontSize * contentFontScale,
                    child: _renderCooked(
                      context,
                      post: post,
                      heroTagNamespace: 'reply_history_${post.postNumber}',
                      contentFontScale: contentFontScale,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开的直接回复的几何:整体缩进一级,竖线走当前帖头像中心
abstract final class EmbeddedReplyMetrics {
  /// 当前帖头像中心(PostAvatar 默认半径 20)
  static const double railCenter = 20;
  static const double railWidth = 1.5;

  /// 回复内容起排位置 = 竖线 + 一级缩进
  static const double indent = 32;
  static const double buttonSize = 28;
}

/// 展开的单条直接回复:与主帖同构的迷你帖——头像与名字一行,正文在下
/// 占满缩进后的宽度。点击跳到该楼层。
class EmbeddedReplyTile extends StatelessWidget {
  static const double _inkInset = 6;

  final Post post;
  final double contentFontScale;
  final VoidCallback? onTap;

  const EmbeddedReplyTile({
    super.key,
    required this.post,
    this.contentFontScale = 1.0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = post.getAvatarUrl(size: 48);
    return Padding(
      // 点击高亮比内容外扩一点,内容本身对齐缩进线
      padding: const EdgeInsetsDirectional.only(
        start: EmbeddedReplyMetrics.indent - _inkInset,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _inkInset,
              vertical: 8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SmartAvatar(
                      imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                      radius: 12,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      fallbackText: post.username,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _displayName(post),
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '#${post.postNumber}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _renderCooked(
                  context,
                  post: post,
                  heroTagNamespace: 'reply_preview_${post.postNumber}',
                  contentFontScale: contentFontScale,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 回复区左侧竖线(放在 Stack 里)
class EmbeddedReplyRail extends StatelessWidget {
  final double? top;
  final double? bottom;

  const EmbeddedReplyRail({super.key, this.top, this.bottom});

  @override
  Widget build(BuildContext context) {
    return PositionedDirectional(
      start:
          EmbeddedReplyMetrics.railCenter - EmbeddedReplyMetrics.railWidth / 2,
      top: top,
      bottom: bottom,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.outlineVariant,
        child: const SizedBox(width: EmbeddedReplyMetrics.railWidth),
      ),
    );
  }
}

/// 回复区竖线末端的收起按钮
class EmbeddedReplyCollapseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const EmbeddedReplyCollapseButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(8),
      side: BorderSide(color: theme.colorScheme.outlineVariant),
    );
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start:
            EmbeddedReplyMetrics.railCenter -
            EmbeddedReplyMetrics.buttonSize / 2,
      ),
      child: Tooltip(
        message: context.l10n.post_collapseReplies,
        child: Material(
          color: Colors.transparent,
          shape: shape,
          child: InkWell(
            onTap: onPressed,
            customBorder: shape,
            child: SizedBox.square(
              dimension: EmbeddedReplyMetrics.buttonSize,
              child: Icon(
                Symbols.keyboard_arrow_up_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 超长内容折叠:收起时截到 [foldedLines] 行并渐隐,超出时下方给展开/收起
class _FoldableContent extends StatefulWidget {
  final int foldedLines;
  final bool unfolded;
  final VoidCallback onToggleUnfold;
  final double fontSize;
  final Widget child;

  const _FoldableContent({
    required this.foldedLines,
    required this.unfolded,
    required this.onToggleUnfold,
    required this.fontSize,
    required this.child,
  });

  @override
  State<_FoldableContent> createState() => _FoldableContentState();
}

class _FoldableContentState extends State<_FoldableContent> {
  bool _overflows = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folded = !widget.unfolded;
    Widget content = _FoldedHeight(
      foldedHeight:
          MediaQuery.textScalerOf(context).scale(widget.fontSize) *
          _embeddedLineHeight *
          widget.foldedLines,
      folded: folded,
      onOverflowChanged: (overflows) {
        if (mounted && overflows != _overflows) {
          setState(() => _overflows = overflows);
        }
      },
      child: widget.child,
    );
    if (folded && _overflows) {
      content = ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black, Colors.transparent],
          stops: [0.6, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: content,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        if (_overflows)
          TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 32),
              alignment: AlignmentDirectional.centerStart,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.labelMedium,
            ),
            onPressed: widget.onToggleUnfold,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.unfolded
                      ? context.l10n.post_foldFullText
                      : context.l10n.post_unfoldFullText,
                ),
                const SizedBox(width: 2),
                Icon(
                  widget.unfolded
                      ? Symbols.keyboard_arrow_up_rounded
                      : Symbols.keyboard_arrow_down_rounded,
                  size: 16,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 按完整高度布局子树,[folded] 时截到 [foldedHeight] 并裁切;
/// 是否超出折叠高度经 [onOverflowChanged] 回报(展开后仍照实回报,
/// 收起按钮才不会消失)。
class _FoldedHeight extends SingleChildRenderObjectWidget {
  final double foldedHeight;
  final bool folded;
  final ValueChanged<bool> onOverflowChanged;

  const _FoldedHeight({
    required this.foldedHeight,
    required this.folded,
    required this.onOverflowChanged,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFoldedHeight(foldedHeight, folded, onOverflowChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFoldedHeight renderObject,
  ) {
    renderObject
      ..foldedHeight = foldedHeight
      ..folded = folded
      ..onOverflowChanged = onOverflowChanged;
  }
}

class _RenderFoldedHeight extends RenderProxyBox {
  _RenderFoldedHeight(this._foldedHeight, this._folded, this.onOverflowChanged);

  ValueChanged<bool> onOverflowChanged;
  bool? _reportedOverflow;
  bool _clipped = false;

  double _foldedHeight;
  set foldedHeight(double value) {
    if (value == _foldedHeight) return;
    _foldedHeight = value;
    markNeedsLayout();
  }

  bool _folded;
  set folded(bool value) {
    if (value == _folded) return;
    _folded = value;
    markNeedsLayout();
  }

  Size _clamp(BoxConstraints constraints, Size childSize) {
    final height = _folded && childSize.height > _foldedHeight
        ? _foldedHeight
        : childSize.height;
    return constraints.constrain(Size(childSize.width, height));
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      constraints.copyWith(minHeight: 0, maxHeight: double.infinity);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return _clamp(
      constraints,
      child.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = _clamp(constraints, child.size);
    _clipped = size.height < child.size.height;
    final overflows = child.size.height > _foldedHeight + 0.5;
    if (overflows != _reportedOverflow) {
      _reportedOverflow = overflows;
      // 布局期不能触发重建,回报推到帧末
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onOverflowChanged(overflows),
      );
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_clipped) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      super.paint,
      oldLayer: layer as ClipRectLayer?,
    );
  }

  @override
  void dispose() {
    layer = null;
    super.dispose();
  }
}
