import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../utils/emoji_shortcodes.dart';
import '../../../utils/markdown_block_format.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../widgets/markdown_editor/composer_shortcuts.dart';
import '../../../widgets/markdown_editor/emoji_picker.dart';
import '../../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../../../widgets/common/character_counts_overlay.dart';
import '../../../utils/platform_utils.dart';
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
    this.resolveMinLength,
  });

  final TopicReplySession session;

  /// 解析最小正文字数（与完整编辑器同一口径，含站点插件按分类的改写）；
  /// 展开时解析一次，驱动字数计数
  final Future<int> Function()? resolveMinLength;

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
  int? _minLength;

  /// 移动端表情面板：占据键盘的位置（键盘收起、面板顶上来，输入区不动）
  bool _emojiMode = false;

  /// 从表情面板切回键盘的过渡期：键盘升起前继续占位，输入区不下坠
  bool _returningToKeyboard = false;

  /// 最近一次键盘完全展开的高度；表情面板按它定高
  double _keyboardHeight = 0;
  static const double _fallbackPanelHeight = 300;

  bool get _inlineEmoji => !PlatformUtils.isDesktop;

  TopicReplySession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
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
      _loadMinLength();
      _controller.forward();
    } else if (_session.handingOff) {
      // 已被完整编辑器盖住：直接消失，不播收起动画
      _controller.value = 0;
    } else {
      _captureSource();
      _controller.reverse();
    }
    if (!_session.active && (_emojiMode || _returningToKeyboard)) {
      setState(() {
        _emojiMode = false;
        _returningToKeyboard = false;
      });
    }
  }

  Future<void> _loadMinLength() async {
    final resolve = widget.resolveMinLength;
    if (resolve == null) return;
    try {
      final min = await resolve();
      if (mounted) setState(() => _minLength = min);
    } catch (_) {
      // 解析失败不显示计数；发送时仍会按完整规则校验
    }
  }

  /// 系统键盘的实际高度（不受 Scaffold 调整 body 影响）
  double get _viewInsetBottom {
    final view = View.of(context);
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = _viewInsetBottom;
    var changed = false;
    // 只记录键盘完全展开后的高度（升降过程中的中间值不算）
    if (inset > _keyboardHeight && !_emojiMode) {
      _keyboardHeight = inset;
      changed = true;
    }
    if (_returningToKeyboard && inset >= _panelHeight - 1) {
      _returningToKeyboard = false;
      changed = true;
    }
    if (changed || _emojiMode || _returningToKeyboard) setState(() {});
  }

  double get _panelHeight =>
      _keyboardHeight > 0 ? _keyboardHeight : _fallbackPanelHeight;

  /// 表情面板区当前要占的高度：面板高减去仍在屏上的键盘部分。键盘收起
  /// 的过程中它随之长高、切回键盘时随之缩回，输入区始终不动
  double get _emojiAreaHeight {
    if (!_emojiMode && !_returningToKeyboard) return 0;
    return (_panelHeight - _viewInsetBottom).clamp(0.0, _panelHeight);
  }

  void _toggleEmojiPanel() {
    if (!_inlineEmoji) {
      _pickEmoji();
      return;
    }
    if (_emojiMode) {
      _switchToKeyboard();
    } else {
      setState(() {
        _emojiMode = true;
        _returningToKeyboard = false;
      });
      // readOnly 让系统键盘收起、焦点与光标保留
      _session.focusNode.requestFocus();
    }
  }

  void _switchToKeyboard() {
    if (!_emojiMode) return;
    setState(() {
      _emojiMode = false;
      _returningToKeyboard = true;
    });
    _session.focusNode.requestFocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
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

  /// 守卫与发送按钮一致：有内容且不在发送中
  void _submitFromShortcut() {
    if (_session.hasContent && !_session.submitting) widget.onSend();
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
                        // 发送快捷键与完整编辑器同一套（Cmd/Ctrl+Enter）
                        child: CallbackShortcuts(
                          bindings: {
                            for (final activator in composerSubmitActivators())
                              activator: _submitFromShortcut,
                          },
                          child: KeyedSubtree(
                            key: _panelKey,
                            child: _buildPanel(context, theme, floating),
                          ),
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
        final emojiArea = _emojiAreaHeight;
        final content = Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            target == null ? 16 : 8,
            12,
            // 表情面板占位时由面板贴底；否则贴底形态自己让出底部安全区，
            // 悬浮卡片已离开底边
            emojiArea > 0 || floating
                ? 8
                : 8 + MediaQuery.paddingOf(context).bottom,
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
                  // 表情面板打开时只读：系统键盘收起，焦点与光标保留
                  readOnly: _emojiMode,
                  showCursor: true,
                  onTap: _switchToKeyboard,
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
              // 最小字数计数（与完整编辑器同一组件与口径）
              if (_minLength != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 4),
                  child: CharacterCountsOverlay(
                    length: _session.text.text.length,
                    minimumLength: _minLength,
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
                  // 表情面板打开时变为键盘按钮，点按切回键盘
                  IconButton(
                    onPressed: _toggleEmojiPanel,
                    tooltip: _emojiMode
                        ? l10n.topicDetail_quickReplyKeyboard
                        : l10n.topicDetail_quickReplyEmoji,
                    icon: Icon(
                      _emojiMode
                          ? Symbols.keyboard_rounded
                          : Symbols.mood_rounded,
                    ),
                    color: _emojiMode
                        ? context.emphasis.selected
                        : theme.colorScheme.onSurfaceVariant,
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
              // 最近用过的表情，点按直接插入（表情面板打开时由面板承担）
              if (_recentEmojis.isNotEmpty && emojiArea == 0)
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
        if (emojiArea == 0) return content;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            content,
            // 面板按完整高度布局、外框随键盘升降裁切，过渡中不逐帧重排
            SizedBox(
              height: emojiArea,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: _panelHeight,
                  maxHeight: _panelHeight,
                  child: EmojiStickerPanel(
                    onEmojiSelected: (emoji) => _insertEmoji(emoji.name),
                    onStickerSelected: _session.insertText,
                    onBackspace: () =>
                        deleteBackwardWithEmojiShortcodes(_session.text),
                  ),
                ),
              ),
            ),
          ],
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
