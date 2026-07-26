import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面端表情悬浮弹层的固定尺寸
const Size kEmojiPopoverSize = Size(440, 480);

/// 弹层与锚点/屏幕边缘的间距
const double _kPopoverMargin = 8.0;

/// 弹层圆角
const double _kPopoverRadius = 14.0;

/// 桌面端表情悬浮弹层控制器。
///
/// 由编辑器 State 持有(与 FocusNode 同生命周期)。取代移动端的
/// docked 占位面板:在工具栏表情按钮上方(空间不足则下方)弹出
/// 固定尺寸的悬浮面板,点外部/Esc/再点按钮关闭,选表情不关闭。
///
/// 关键机制(基于 TapRegionSurface 挂在 WidgetsApp 根部、groupId
/// 分组跨 Overlay 生效的事实):
/// - 弹层内容包 [TextFieldTapRegion] → 点弹层不触发编辑器 TextField
///   失焦(与 docked 面板同语义);
/// - 弹层与工具栏按钮([EmojiPopoverAnchor])共用本实例作 groupId →
///   点按钮时弹层的 onTapOutside 不触发,由按钮 onPressed 干净 toggle,
///   根除"外点先关、按钮再开"的闪烁竞争。
class EmojiPopoverController with ChangeNotifier, WidgetsBindingObserver {
  /// 打开/重建时量按钮全局 Rect,决定弹层位置与上/下翻转。
  ///
  /// 不用 LayerLink/CompositedTransformFollower:FollowerLayer 的变换
  /// 要到 paint 阶段才可靠,面板内 Tooltip(OverlayPortal 布局器)在
  /// layout 阶段算 paint transform 会命中它,每帧报
  /// "The paint transform cannot be reliably computed"。而本场景外点
  /// 即关(pointerDown 就触发 onTapOutside),弹层打开期间锚点不可能
  /// 被用户拖走;窗口 resize 由 didChangeMetrics 重建覆盖 —— 静态
  /// Positioned 足够。
  final GlobalKey anchorKey = GlobalKey();

  /// 退场动画壳(hide 时先 reverse 再移除 entry)
  final GlobalKey<_PopoverShellState> _shellKey = GlobalKey();

  OverlayEntry? _entry;

  /// 退场动画进行中(entry 还挂着但语义上已关闭)
  bool _closing = false;

  /// 关闭票据:退场动画完成回调用它识别"是否已被后来者接管"
  /// (动画期间再次 show 会立即终结旧 entry,旧回调作废)
  int _ticket = 0;

  bool get isOpen => _entry != null && !_closing;

  void toggle(BuildContext context, {required Widget panel}) {
    if (isOpen) {
      hide();
    } else {
      show(context, panel: panel);
    }
  }

  void show(BuildContext context, {required Widget panel}) {
    if (isOpen) return;
    // 退场动画中被重开:旧弹层立即终结,避免同帧双 entry
    if (_entry != null) _removeEntryNow();
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: (context) => _buildPopover(context, panel));
    overlay.insert(_entry!);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
  }

  void hide() {
    if (!isOpen) return;
    _closing = true;
    _detachGlobalHooks();
    notifyListeners();
    final shell = _shellKey.currentState;
    if (shell == null) {
      _removeEntryNow();
      return;
    }
    final ticket = ++_ticket;
    // whenCompleteOrCancel:正常播完或 shell 被销毁(entry 强移)都回调,
    // 票据不匹配说明已被 show()/dispose() 抢先清理
    shell.reverse().whenCompleteOrCancel(() {
      if (_ticket == ticket) _removeEntryNow();
    });
  }

  void _removeEntryNow() {
    _ticket++;
    final entry = _entry;
    _entry = null;
    _closing = false;
    entry?.remove();
    entry?.dispose();
  }

  void _detachGlobalHooks() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void dispose() {
    // 宿主编辑器 dispose(如回复 sheet 关闭)必须立即带走弹层
    // (不等退场动画),否则 OverlayEntry / 键盘 handler 泄漏
    _detachGlobalHooks();
    _removeEntryNow();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!isOpen) return false;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      hide();
      return true;
    }
    return false;
  }

  /// 窗口 resize:锚点还在则按新几何重建(翻转方向/clamp 重算),
  /// 锚点没了(编辑器被移出树)直接关闭
  @override
  void didChangeMetrics() {
    if (!isOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isOpen) return;
      final box = anchorKey.currentContext?.findRenderObject();
      if (box is RenderBox && box.attached) {
        _entry!.markNeedsBuild();
      } else {
        hide();
      }
    });
  }

  Widget _buildPopover(BuildContext context, Widget panel) {
    final anchorBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (anchorBox == null || !anchorBox.attached) {
      return const SizedBox.shrink();
    }
    final anchorRect =
        anchorBox.localToGlobal(Offset.zero) & anchorBox.size;
    final screenSize = MediaQuery.sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);

    // 窗口过窄时缩宽,保证左右都留边距
    final width = math.min(
      kEmojiPopoverSize.width,
      screenSize.width - _kPopoverMargin * 2,
    );

    // 上/下翻转:优先上方(按钮在编辑器工具栏,弹上方不遮编辑区),
    // 两侧都不足取大侧并缩高,防窗口极矮 overflow
    final spaceAbove =
        anchorRect.top - viewPadding.top - _kPopoverMargin * 2;
    final spaceBelow = screenSize.height -
        viewPadding.bottom -
        anchorRect.bottom -
        _kPopoverMargin * 2;
    final bool showAbove;
    final double height;
    if (spaceAbove >= kEmojiPopoverSize.height) {
      showAbove = true;
      height = kEmojiPopoverSize.height;
    } else if (spaceBelow >= kEmojiPopoverSize.height) {
      showAbove = false;
      height = kEmojiPopoverSize.height;
    } else {
      showAbove = spaceAbove >= spaceBelow;
      height = math.max(
        160.0,
        math.min(kEmojiPopoverSize.height, showAbove ? spaceAbove : spaceBelow),
      );
    }

    // 水平 clamp 进屏(表情按钮在最左,通常直接对齐按钮左缘)
    final maxLeft = math.max(
      _kPopoverMargin,
      screenSize.width - width - _kPopoverMargin,
    );
    final left = anchorRect.left.clamp(_kPopoverMargin, maxLeft);

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Positioned(
      left: left,
      width: width,
      height: height,
      // 静态定位:上弹以按钮顶为底边,下弹以按钮底为顶边
      top: showAbove
          ? anchorRect.top - _kPopoverMargin - height
          : anchorRect.bottom + _kPopoverMargin,
      // 动画壳:从按钮侧的角缩放生长 + 淡入,退场反向
      child: _PopoverShell(
        key: _shellKey,
        alignment: showAbove ? Alignment.bottomLeft : Alignment.topLeft,
        // TextFieldTapRegion:点弹层不触发编辑器 TextField 失焦;
        // TapRegion(groupId: this):点弹层与锚点按钮之外才关闭
        child: TextFieldTapRegion(
          child: TapRegion(
            groupId: this,
            onTapOutside: (_) => hide(),
            child: Container(
              width: width,
              height: height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(_kPopoverRadius),
                // 双层阴影:大范围柔和主影 + 近距离细影,
                // 比 Material elevation 的默认投影轻盈(桌面弹层观感)
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: isDark ? 0.45 : 0.14,
                    ),
                    blurRadius: 32,
                    spreadRadius: -4,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: isDark ? 0.30 : 0.08,
                    ),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              // 边框走前景:decoration 的 border 画在子内容之下,
              // 面板背景同被裁进圆角矩形会盖住描边(四角尤其明显)
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_kPopoverRadius),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: isDark ? 0.6 : 0.5,
                  ),
                ),
              ),
              // Overlay 里没有 Material 祖先,面板内 InkWell 需要
              child: Material(
                type: MaterialType.transparency,
                child: panel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹层开合动画壳:缩放(0.94→1,从锚点侧的角生长)+ 淡入;
/// 退场由 controller.hide() 调 [reverse] 播反向后再移除 entry。
class _PopoverShell extends StatefulWidget {
  final Alignment alignment;
  final Widget child;

  const _PopoverShell({
    super.key,
    required this.alignment,
    required this.child,
  });

  @override
  State<_PopoverShell> createState() => _PopoverShellState();
}

class _PopoverShellState extends State<_PopoverShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    reverseDuration: const Duration(milliseconds: 120),
  );
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  late final CurvedAnimation _scaleCurve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _scale =
      Tween<double>(begin: 0.94, end: 1.0).animate(_scaleCurve);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  /// 播退场动画;正常播完或中途被销毁都会回调 whenCompleteOrCancel
  TickerFuture reverse() => _controller.reverse();

  @override
  void dispose() {
    _fade.dispose();
    _scaleCurve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: _scale,
        alignment: widget.alignment,
        child: widget.child,
      ),
    );
  }
}

/// 工具栏侧锚点包装:包住表情按钮胶囊。
///
/// - [KeyedSubtree]:弹层打开/重建时量按钮全局 Rect 定位;
/// - [TapRegion](groupId: controller):把按钮排除在弹层的
///   onTapOutside 判定外,toggle 无闪烁。
class EmojiPopoverAnchor extends StatelessWidget {
  final EmojiPopoverController controller;
  final Widget child;

  const EmojiPopoverAnchor({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: controller,
      child: KeyedSubtree(key: controller.anchorKey, child: child),
    );
  }
}
