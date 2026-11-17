import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../utils/emoji_shortcodes.dart';
import '../../../utils/markdown_block_format.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../widgets/markdown_editor/emoji_picker.dart';
import '../../../utils/responsive.dart';
import '../controllers/topic_reply_session.dart';
import 'topic_bottom_bar.dart';

/// 快捷回复层：页面压暗，底部升起回复面板，随键盘上移。
///
/// 面板从底栏的回复入口胶囊原地「长」出来（外形、圆角、底色连续变形），
/// 收起时缩回胶囊；展开到完整编辑器时由完整编辑器从面板当前外形继续长大，
/// 整个过程一镜到底。只承载纯文本与表情，其余交给完整编辑器。
class TopicQuickReplyLayer extends StatefulWidget {
  const TopicQuickReplyLayer({
    super.key,
    required this.session,
    required this.sourceKey,
    required this.hint,
    required this.onSend,
    required this.onExpand,
    this.richEditorAvailable = false,
  });

  final TopicReplySession session;

  /// 富文本编辑器可用：正文出现块级格式（快捷回复里会露出源码）时提示展开
  final bool richEditorAvailable;

  /// 底栏回复入口胶囊：面板从它的位置与外形长出
  final GlobalKey sourceKey;
  final String hint;
  final VoidCallback onSend;

  /// 展开到完整编辑器：参数为面板当前的全局外形（矩形、圆角、底色）
  final void Function(Rect rect, double radius, Color color) onExpand;

  @override
  State<TopicQuickReplyLayer> createState() => _TopicQuickReplyLayerState();
}

/// 胶囊相对层底边的位置：键盘升起时层整体变矮，胶囊随之上移，
/// 以底边为基准记录，变形起点就始终跟得上
typedef _SourceGeometry = ({
  double left,
  double width,
  double height,
  double bottomGap,
});

class _TopicQuickReplyLayerState extends State<TopicQuickReplyLayer>
    with SingleTickerProviderStateMixin {
  static const double _panelRadius = 24;
  static const Curve _geometryCurve = Curves.easeInOutCubicEmphasized;
  static const Curve _contentCurve = Interval(0.35, 1, curve: Curves.easeOut);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 260),
  )..addStatusListener(_onStatus);

  final GlobalKey _panelKey = GlobalKey();
  _SourceGeometry? _source;
  List<String> _recentEmojis = const [];

  TopicReplySession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.activeNotifier.addListener(_onActiveChanged);
    if (_session.active) _onActiveChanged();
  }

  @override
  void didUpdateWidget(covariant TopicQuickReplyLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.activeNotifier.removeListener(_onActiveChanged);
      widget.session.activeNotifier.addListener(_onActiveChanged);
    }
  }

  @override
  void dispose() {
    _session.activeNotifier.removeListener(_onActiveChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    _session.presentedNotifier.value = status != AnimationStatus.dismissed;
  }

  void _onActiveChanged() {
    if (_session.active) {
      _captureSource();
      _loadRecentEmojis();
      _controller.forward();
    } else if (_session.handingOff) {
      // 已被完整编辑器盖住：直接消失，不播收起动画
      _controller.value = 0;
    } else {
      _captureSource();
      _controller.reverse();
    }
  }

  void _captureSource() {
    final layer = context.findRenderObject() as RenderBox?;
    final pill =
        widget.sourceKey.currentContext?.findRenderObject() as RenderBox?;
    if (layer == null || !layer.hasSize || pill == null || !pill.attached) {
      return;
    }
    final topLeft = layer.globalToLocal(pill.localToGlobal(Offset.zero));
    _source = (
      left: topLeft.dx,
      width: pill.size.width,
      height: pill.size.height,
      bottomGap: layer.size.height - topLeft.dy - pill.size.height,
    );
  }

  Future<void> _loadRecentEmojis() async {
    final names = await loadRecentEmojiNames();
    if (mounted) setState(() => _recentEmojis = names);
  }

  Future<void> _pickEmoji() async {
    final name = await AppBottomSheet.showDraggable<String>(
      context: context,
      initialSize: 0.55,
      minSize: 0.4,
      bodyBuilder: (pickerContext, scrollController) => EmojiPicker(
        onEmojiSelected: (emoji) => Navigator.pop(pickerContext, emoji.name),
      ),
    );
    if (name != null) _insertEmoji(name);
    if (mounted && _session.active) _session.focusNode.requestFocus();
  }

  void _insertEmoji(String name) {
    _session.insertText(':$name:');
    recordRecentEmoji(name);
  }

  void _expand() {
    final panel = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (panel == null || !panel.hasSize) return;
    widget.onExpand(
      panel.localToGlobal(Offset.zero) & panel.size,
      context.shapes.resolve(_panelRadius),
      Theme.of(context).colorScheme.surfaceContainerLow,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final raw = _controller.value;
        if (raw == 0) return const SizedBox.shrink();
        final t = _geometryCurve.transform(raw);
        final contentOpacity = _contentCurve.transform(raw);
        return Stack(
          children: [
            // 压暗页面，点按收起（未发内容留作草稿）
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _session.close,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.32 * raw),
                ),
              ),
            ),
            _buildMorphingPanel(context, theme, t, contentOpacity),
          ],
        );
      },
    );
  }

  /// 手机宽度贴底（顶部圆角）；更宽时与底栏一致，是帖子列宽度内的悬浮
  /// 卡片（四角圆角、离底边留白）
  Widget _buildMorphingPanel(
    BuildContext context,
    ThemeData theme,
    double t,
    double contentOpacity,
  ) {
    final floating = TopicBottomBarMetrics.isFloating(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final panelBottom = floating
        ? safeBottom + TopicBottomBarMetrics.floatingMargin
        : 0.0;
    final panelRadius = context.shapes.resolve(_panelRadius);
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layerWidth = constraints.maxWidth;
          final panelWidth = floating
              ? (layerWidth - TopicBottomBarMetrics.floatingMargin * 2).clamp(
                  0.0,
                  Breakpoints.maxContentWidth,
                )
              : layerWidth;
          final panelLeft = (layerWidth - panelWidth) / 2;
          return Stack(
            children: [
              Positioned(
                left: panelLeft,
                width: panelWidth,
                bottom: panelBottom,
                child: ClipPath(
                  clipper: _MorphClipper(
                    source: _source,
                    panelLeft: panelLeft,
                    panelBottom: panelBottom,
                    t: t,
                    topRadius: panelRadius,
                    bottomRadius: floating ? panelRadius : 0,
                  ),
                  child: ColoredBox(
                    color: Color.lerp(
                      theme.colorScheme.surfaceContainerHighest,
                      theme.colorScheme.surfaceContainerLow,
                      t,
                    )!,
                    child: Opacity(
                      opacity: contentOpacity,
                      // 面板内的点按不算「点到输入框外」，不会先把焦点收走
                      child: TextFieldTapRegion(
                        child: KeyedSubtree(
                          key: _panelKey,
                          child: _buildPanel(context, theme, floating),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPanel(BuildContext context, ThemeData theme, bool floating) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final target = _session.target;
        final canSend = _session.hasContent && !_session.submitting;
        final suggestExpand =
            widget.richEditorAvailable &&
            markdownHasBlockFormatting(_session.text.text);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            target == null ? 16 : 8,
            12,
            // 贴底形态自己让出底部安全区；悬浮卡片已离开底边
            floating ? 8 : 8 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (target != null)
                Row(
                  children: [
                    Icon(
                      Symbols.reply_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        l10n.topicDetail_quickReplyReplyingTo(
                          target.postNumber,
                          target.username,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _session.clearTarget,
                      tooltip: l10n.common_cancel,
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      icon: const Icon(Symbols.close_rounded),
                    ),
                  ],
                ),
              // 输入区
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(16),
                  ),
                ),
                child: TextField(
                  controller: _session.text,
                  focusNode: _session.focusNode,
                  minLines: 3,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  // 退格删到表情时整个短代码一起删（与 Boost、聊天输入一致）
                  inputFormatters: const [EmojiShortcodeDeleteFormatter()],
                  style: theme.textTheme.bodyLarge,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    isDense: true,
                    contentPadding: const EdgeInsets.all(14),
                  ).withoutBorder(),
                ),
              ),
              if (suggestExpand)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    l10n.topicDetail_quickReplyFormattingHint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              // 工具条：表情、展开 …… 发送
              Row(
                children: [
                  IconButton(
                    onPressed: _pickEmoji,
                    tooltip: l10n.topicDetail_quickReplyEmoji,
                    icon: const Icon(Symbols.mood_rounded),
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  // 内容含格式时突出展开按钮
                  suggestExpand
                      ? IconButton.filledTonal(
                          onPressed: _expand,
                          tooltip: l10n.topicDetail_quickReplyExpand,
                          icon: const Icon(Symbols.open_in_full_rounded),
                        )
                      : IconButton(
                          onPressed: _expand,
                          tooltip: l10n.topicDetail_quickReplyExpand,
                          icon: const Icon(Symbols.open_in_full_rounded),
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                  const Spacer(),
                  FilledButton(
                    onPressed: canSend ? widget.onSend : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: _session.submitting
                        ? SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : Text(l10n.common_send),
                  ),
                ],
              ),
              // 最近用过的表情，点按直接插入
              if (_recentEmojis.isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _recentEmojis.length,
                    itemBuilder: (context, index) {
                      final name = _recentEmojis[index];
                      return InkWell(
                        onTap: () => _insertEmoji(name),
                        customBorder: RoundedSuperellipseBorder(
                          borderRadius: context.shapes.borderRadius(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: EmojiImage(name, size: 28),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 面板外形：从胶囊（[source]）连续变形到整块面板
class _MorphClipper extends CustomClipper<Path> {
  const _MorphClipper({
    required this.source,
    required this.panelLeft,
    required this.panelBottom,
    required this.t,
    required this.topRadius,
    required this.bottomRadius,
  });

  /// 胶囊相对层的位置（以层底边为基准）
  final _SourceGeometry? source;

  /// 面板相对层的左边距、离层底边的距离：把胶囊换算到面板坐标
  final double panelLeft;
  final double panelBottom;
  final double t;
  final double topRadius;
  final double bottomRadius;

  @override
  Path getClip(Size size) {
    final full = Offset.zero & size;
    final s = source;
    final from = s == null
        ? Rect.fromLTWH(0, size.height, size.width, 0)
        : Rect.fromLTWH(
            s.left - panelLeft,
            size.height - (s.bottomGap - panelBottom) - s.height,
            s.width,
            s.height,
          );
    final rect = Rect.lerp(from, full, t)!;
    final fromRadius = s == null ? 0.0 : s.height / 2;
    final top = Radius.circular(fromRadius + (topRadius - fromRadius) * t);
    final bottom = Radius.circular(
      fromRadius + (bottomRadius - fromRadius) * t,
    );
    return Path()..addRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: top,
        topRight: top,
        bottomLeft: bottom,
        bottomRight: bottom,
      ),
    );
  }

  @override
  bool shouldReclip(_MorphClipper old) =>
      old.source != source ||
      old.panelLeft != panelLeft ||
      old.panelBottom != panelBottom ||
      old.t != t ||
      old.topRadius != topRadius ||
      old.bottomRadius != bottomRadius;
}
