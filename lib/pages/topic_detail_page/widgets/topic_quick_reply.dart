import 'dart:async';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../utils/emoji_shortcodes.dart';
import '../../../utils/markdown_block_format.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../widgets/markdown_editor/composer_shortcuts.dart';
import '../../../widgets/markdown_editor/composer_panel_height.dart';
import '../../../widgets/markdown_editor/emoji_picker.dart';
import '../../../widgets/markdown_editor/emoji_sticker_panel.dart';
import '../../../widgets/common/character_counts_overlay.dart';
import '../../../utils/platform_utils.dart';
import '../../../utils/responsive.dart';
import '../controllers/topic_reply_session.dart';
import 'topic_bottom_bar.dart';

/// 快捷回复层：整页（含顶栏）压暗，底部升起回复面板，随键盘上移。须挂在
/// 话题页 Scaffold 之外的最上层，遮罩才能盖住整个页面。
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
  final ValueChanged<QuickReplyExpansion> onExpand;

  @override
  State<TopicQuickReplyLayer> createState() => _TopicQuickReplyLayerState();
}

/// 展开到完整编辑器时交给宿主的起点：面板的全局外形、底色、截图，以及
/// 编辑器首帧回调（面板在这一帧隐藏，由截图接替）
typedef QuickReplyExpansion = ({
  Rect rect,
  double radius,
  Color color,
  ui.Image? snapshot,
  VoidCallback onShown,
});

/// 胶囊相对层底边的位置：键盘升起时层整体变矮，胶囊随之上移，
/// 以底边为基准记录，变形起点就始终跟得上
typedef _SourceGeometry = ({
  double left,
  double width,
  double height,
  double bottomGap,
});

class _TopicQuickReplyLayerState extends State<TopicQuickReplyLayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _panelRadius = 24;
  static const Curve _geometryCurve = Curves.easeInOutCubicEmphasized;
  static const Curve _contentCurve = Interval(0.35, 1, curve: Curves.easeOut);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 260),
  )..addStatusListener(_onStatus);

  /// 整块面板（含底色与外形）的截图边界：展开时交给编辑器接替面板
  final GlobalKey _snapshotKey = GlobalKey();

  /// 展开到完整编辑器期间：面板已由编辑器接替（隐藏但保持挂载，输入框
  /// 焦点与键盘不断），遮罩随编辑器自己的遮罩淡入而淡出
  bool _handedOff = false;
  late final AnimationController _handoffFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  _SourceGeometry? _source;
  List<String> _recentEmojis = const [];
  int? _minLength;

  /// 移动端表情面板：占据键盘的位置（键盘收起、面板顶上来，输入区不动）
  bool _emojiMode = false;

  /// 从表情面板切回键盘的过渡期：键盘升起前继续占位，输入区不下坠
  bool _returningToKeyboard = false;
  Timer? _keyboardReturnTimeout;

  double _panelHeight = 300;
  bool get _holdsPanel => _emojiMode || _returningToKeyboard;

  late final _emojiPanel = EmojiStickerPanel(
    onEmojiSelected: (emoji) => _insertEmoji(emoji.name),
    onStickerSelected: (text) => _session.insertText(text),
    onBackspace: () => deleteBackwardWithEmojiShortcodes(_session.text),
  );

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
    _keyboardReturnTimeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _session.activeNotifier.removeListener(_onActiveChanged);
    _controller.dispose();
    _handoffFade.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    _session.presentedNotifier.value = status != AnimationStatus.dismissed;
  }

  void _onActiveChanged() {
    if (_session.active) {
      if (_handedOff) {
        _handedOff = false;
        _handoffFade.value = 0;
      }
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
    if (!_session.active && _holdsPanel) {
      _keyboardReturnTimeout?.cancel();
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
    if (_returningToKeyboard && _viewInsetBottom >= _panelHeight - 1) {
      _finishKeyboardReturn();
    }
  }

  void _finishKeyboardReturn() {
    _keyboardReturnTimeout?.cancel();
    setState(() => _returningToKeyboard = false);
  }

  void _toggleEmojiPanel() {
    if (!_inlineEmoji) {
      _pickEmoji();
      return;
    }
    if (_emojiMode) {
      _switchToKeyboard();
    } else {
      _keyboardReturnTimeout?.cancel();
      setState(() {
        if (!_returningToKeyboard) {
          _panelHeight = resolveComposerPanelHeight(
            keyboardHeight: _viewInsetBottom,
            fallbackHeight: 300,
            safeBottom: MediaQuery.viewPaddingOf(context).bottom,
          );
        }
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
      _returningToKeyboard = _viewInsetBottom < _panelHeight - 1;
    });
    _session.focusNode.requestFocus();
    // 已聚焦的输入框解除只读后会自行恢复输入连接。外接键盘或较矮的
    // 输入法可能始终达不到原高度，届时释放剩余占位。
    if (_returningToKeyboard) {
      _keyboardReturnTimeout = Timer(
        const Duration(milliseconds: 900),
        _finishKeyboardReturn,
      );
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

  /// 守卫与发送按钮一致：有内容且不在发送中
  void _submitFromShortcut() {
    if (_session.hasContent && !_session.submitting) widget.onSend();
  }

  void _expand() {
    final boundary =
        _snapshotKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) return;
    ui.Image? snapshot;
    try {
      snapshot = boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } catch (_) {
      // 截图失败只是少了接替画面，编辑器照常从面板外形长出
    }
    widget.onExpand((
      rect: boundary.localToGlobal(Offset.zero) & boundary.size,
      radius: context.shapes.resolve(_panelRadius),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      snapshot: snapshot,
      onShown: _onEditorShown,
    ));
  }

  void _onEditorShown() {
    if (!mounted) return;
    setState(() => _handedOff = true);
    _handoffFade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final floating = TopicBottomBarMetrics.isFloating(context);
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _handoffFade]),
      child: _buildPanel(context, theme, floating),
      builder: (context, panel) {
        final raw = _controller.value;
        if (raw == 0) return const SizedBox.shrink();
        final t = _geometryCurve.transform(raw);
        final contentOpacity = _contentCurve.transform(raw);
        // 编辑器接替后，本层遮罩随编辑器遮罩淡入而淡出，两者衔接不叠暗
        final scrim = 0.32 * raw * (1 - _handoffFade.value);
        return Stack(
          children: [
            // 压暗页面，点按收起（未发内容留作草稿）
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _session.close,
                child: ColoredBox(color: Colors.black.withValues(alpha: scrim)),
              ),
            ),
            // 编辑器接替后面板只隐藏不卸载：输入框焦点与键盘保持，
            // 由完整编辑器直接接过
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _handedOff,
                child: Opacity(
                  opacity: _handedOff ? 0 : 1,
                  child: Stack(
                    children: [
                      _buildMorphingPanel(
                        context,
                        theme,
                        t,
                        contentOpacity,
                        floating,
                        panel!,
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
    bool floating,
    Widget panel,
  ) {
    // 表情面板先在键盘背后按终态高度布局，系统键盘收起时自然露出。
    final keyboardInset = _holdsPanel
        ? 0.0
        : MediaQuery.viewInsetsOf(context).bottom;
    final panelBottom =
        keyboardInset +
        (floating
            ? MediaQuery.paddingOf(context).bottom +
                  TopicBottomBarMetrics.floatingMargin
            : 0.0);
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
                child: RepaintBoundary(
                  key: _snapshotKey,
                  child: ClipPath(
                    clipper: _MorphClipper(
                      source: _source,
                      panelLeft: panelLeft,
                      panelBottom: panelBottom,
                      t: t,
                      topRadius: panelRadius,
                      bottomRadius: floating ? panelRadius : 0,
                    ),
                    // 本层挂在 Scaffold 之外，面板自己提供 Material：输入框、
                    // 水波纹与图标按钮都要求有 Material 祖先
                    child: Material(
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
                              for (final activator
                                  in composerSubmitActivators())
                                activator: _submitFromShortcut,
                            },
                            child: panel,
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
        final content = Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            target == null ? 16 : 8,
            12,
            // 表情面板占位时由面板贴底；否则贴底形态自己让出底部安全区，
            // 悬浮卡片已离开底边
            _holdsPanel || floating
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
                  // 最小字数计数（与完整编辑器同一组件与口径），放在发送按钮
                  // 左侧，不独占一行；够字数后组件自身隐藏
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: CharacterCountsOverlay(
                        length: _session.text.text.length,
                        minimumLength: _minLength,
                        maxLines: 1,
                      ),
                    ),
                  ),
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
              if (_recentEmojis.isNotEmpty)
                _RecentEmojiStrip(
                  visible: !_emojiMode,
                  names: _recentEmojis,
                  onSelected: _insertEmoji,
                ),
            ],
          ),
        );
        // 输入框在两种模式下使用同一个父节点，交接时保留 EditableText 的输入连接。
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            content,
            if (_holdsPanel) SizedBox(height: _panelHeight, child: _emojiPanel),
          ],
        );
      },
    );
  }
}

class _RecentEmojiStrip extends StatelessWidget {
  const _RecentEmojiStrip({
    required this.visible,
    required this.names,
    required this.onSelected,
  });

  final bool visible;
  final List<String> names;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1.0 : 0.0),
      duration: reduceMotion
          ? Duration.zero
          : TopicBottomBarMetrics.motionDuration,
      curve: TopicBottomBarMetrics.motionCurve,
      child: SizedBox(
        height: 44,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: names.length,
          itemBuilder: (context, index) {
            final name = names[index];
            return InkWell(
              onTap: () => onSelected(name),
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
      builder: (context, factor, child) {
        if (factor == 0) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: !visible,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: factor,
              child: Opacity(opacity: factor, child: child),
            ),
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
