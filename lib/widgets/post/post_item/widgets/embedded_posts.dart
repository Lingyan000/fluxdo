import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../utils/fluxdo_render_callbacks.dart';
import '../../../../utils/platform_utils.dart';
import '../../../common/positioned_stream_list.dart';
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

/// 父帖卡:当前帖的上文,点击跳到该楼层。
///
/// 外壳用主题的分段卡片([SegmentedCardItem]),多层父帖自然成组,形态随
/// 主题的分段 / 描边 / 平铺风格变化;名字前的回复图标与头部回复按钮
/// 同款同色,表明这是它展开的内容。
///
/// 超长正文收起时只露开头 [foldedLines] 行并渐隐,下方给展开/收起;
/// 展开状态由调用方持有([unfolded]/[onToggleUnfold]),随快照保留。
class ParentPostCard extends StatelessWidget {
  /// 分段卡片组的条目间距,与 [SegmentedCardGroup] 默认值一致
  static const double _gap = 3;

  final Post post;

  /// 在父帖链中的位置,决定分段圆角
  final int index;
  final int count;
  final double contentFontScale;
  final VoidCallback? onTap;
  final int foldedLines;
  final bool unfolded;
  final VoidCallback onToggleUnfold;

  const ParentPostCard({
    super.key,
    required this.post,
    required this.index,
    required this.count,
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
    final avatarUrl = post.getAvatarUrl(size: 48);

    return SegmentedCardItem(
      index: index,
      count: count,
      gap: _gap,
      child: InkWell(
        onTap: onTap,
        borderRadius: SegmentedCardItem.borderRadiusOf(
          context,
          index: index,
          count: count,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Symbols.reply_rounded,
                    size: 14,
                    color: context.emphasis.accent,
                  ),
                  const SizedBox(width: 6),
                  SmartAvatar(
                    imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                    radius: 10,
                    backgroundColor: scheme.primaryContainer,
                    fallbackText: post.username,
                  ),
                  const SizedBox(width: 6),
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
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
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
    );
  }
}

/// 展开的直接回复的几何:头像列与当前帖头像等宽,竖线走头像列中心,
/// 名字与正文从当前帖名字的同一位置起排
abstract final class EmbeddedReplyMetrics {
  /// 头像列宽 = 当前帖头像直径(PostAvatar 默认半径 20)
  static const double gutter = 40;

  /// 头像列到文字的间距 = PostHeader 头像与名字的间距
  static const double gap = 12;
  static const double avatarRadius = 14;
  static const double railCenter = gutter / 2;
  static const double railWidth = 1.5;

  /// 收起按钮与回复头像同尺寸,作为这串头像的收尾
  static const double buttonSize = avatarRadius * 2;

  /// 竖线在头像、收起按钮上下断开的间隙
  static const double railGap = 3;

  /// 单条回复的上下内边距;头像顶边距单条顶部即此值
  static const double verticalPadding = 10;
}

/// 展开的单条直接回复:头像在竖线上,名字与正文排在头像右侧。
/// 点击跳到该楼层。
///
/// 竖线由每条自己画:头像上方一段、下方一段,与头像之间留 [EmbeddedReplyMetrics.railGap];
/// 相邻条目首尾相接,拼成只在头像处断开的一根线。[first] 时不画上方
/// 那段(线从首个头像起);[last] 时下方那段在底部留出间隙,接收起按钮。
class EmbeddedReplyTile extends StatelessWidget {
  final Post post;
  final bool first;
  final bool last;
  final double contentFontScale;
  final VoidCallback? onTap;

  const EmbeddedReplyTile({
    super.key,
    required this.post,
    this.first = false,
    this.last = false,
    this.contentFontScale = 1.0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarUrl = post.getAvatarUrl(size: 60);
    return CustomPaint(
      painter: _ReplyRailPainter(
        color: theme.colorScheme.outlineVariant,
        textDirection: Directionality.of(context),
        leading: !first,
        trailingGap: last ? EmbeddedReplyMetrics.railGap : 0,
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
              vertical: EmbeddedReplyMetrics.verticalPadding,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: EmbeddedReplyMetrics.gutter,
                  child: Center(
                    child: SmartAvatar(
                      imageUrl: avatarUrl.isNotEmpty ? avatarUrl : null,
                      radius: EmbeddedReplyMetrics.avatarRadius,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      fallbackText: post.username,
                    ),
                  ),
                ),
                const SizedBox(width: EmbeddedReplyMetrics.gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
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
                      const SizedBox(height: 4),
                      _renderCooked(
                        context,
                        post: post,
                        heroTagNamespace: 'reply_preview_${post.postNumber}',
                        contentFontScale: contentFontScale,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单条回复的竖线:头像上方、下方各一段,与头像之间留间隙
class _ReplyRailPainter extends CustomPainter {
  const _ReplyRailPainter({
    required this.color,
    required this.textDirection,
    required this.leading,
    required this.trailingGap,
  });

  final Color color;
  final TextDirection textDirection;

  /// 是否画头像上方那段(首条不画)
  final bool leading;
  final double trailingGap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    // 头像列在起始侧:从右往左排版时竖线在右侧
    final center = textDirection == TextDirection.rtl
        ? size.width - EmbeddedReplyMetrics.railCenter
        : EmbeddedReplyMetrics.railCenter;
    final left = center - EmbeddedReplyMetrics.railWidth / 2;
    final avatarTop = EmbeddedReplyMetrics.verticalPadding;
    final avatarBottom = avatarTop + EmbeddedReplyMetrics.avatarRadius * 2;
    void segment(double top, double bottom) {
      if (bottom > top) {
        canvas.drawRect(
          Rect.fromLTRB(
            left,
            top,
            left + EmbeddedReplyMetrics.railWidth,
            bottom,
          ),
          paint,
        );
      }
    }

    if (leading) segment(0, avatarTop - EmbeddedReplyMetrics.railGap);
    segment(
      avatarBottom + EmbeddedReplyMetrics.railGap,
      size.height - trailingGap,
    );
  }

  @override
  bool shouldRepaint(_ReplyRailPainter oldDelegate) =>
      color != oldDelegate.color ||
      textDirection != oldDelegate.textDirection ||
      leading != oldDelegate.leading ||
      trailingGap != oldDelegate.trailingGap;
}

/// 回复区竖线末端的收起按钮
class EmbeddedReplyCollapseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const EmbeddedReplyCollapseButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 与竖线同色的细描边圈,和回复头像同尺寸,读作这串头像的收尾
    final shape = context.shapes.circle(
      side: BorderSide(color: theme.colorScheme.outlineVariant),
    );
    Widget button = Material(
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
    );
    // 与操作栏一致:触摸端长按气泡几乎不可达,只在桌面端保留悬停提示
    if (PlatformUtils.isDesktop) {
      button = Tooltip(
        message: context.l10n.post_collapseReplies,
        child: button,
      );
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start:
            EmbeddedReplyMetrics.railCenter -
            EmbeddedReplyMetrics.buttonSize / 2,
      ),
      child: button,
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
            onPressed: () {
              // 收起全文时保持其后内容不动(长父帖收起不越过后面的帖子)
              if (widget.unfolded) {
                PositionedStreamList.keepTrailingEdgeOnShrink(context);
              }
              widget.onToggleUnfold();
            },
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
