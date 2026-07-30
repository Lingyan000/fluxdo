import 'dart:async';
import 'package:flutter/material.dart';

/// 悬浮/长按弹出的小气泡:贴在 [child] 正上方(左边或右边对齐)。
///
/// 不用 OverlayPortal/CompositedTransformFollower——这俩都会在这个 App
/// 的平行视界 GlobalKey 子树搬迁(`_buildMasterPane`:频道详情整棵子树
/// 在"占满右栏"和"退到 master 预览位"之间用同一个 GlobalKey 来回换插
/// 槽)时炸雷:
/// - CompositedTransformFollower 放在 OverlayPortal.overlayChildBuilder
///   里,只在合成阶段才建立变换矩阵,layout 阶段读不到,断言
///   "paint transform cannot be reliably computed"。
/// - 换成 OverlayPortal.overlayChildLayoutBuilder 后触发另一个更深的
///   坑:OverlayPortal 自己也有一套"overlay child 逻辑上还是这里的孩子,
///   物理上搬到 Overlay 里"的 Element 搬迁机制,跟 GlobalKey 子树搬迁撞在
///   同一帧,'_elements.contains(element)' 断言直接崩。
///
/// 改用最朴素的 `Overlay.of(context).insert(OverlayEntry(...))`:纯正常
/// 的 RenderObject 树操作,不接管任何 Element 搬迁魔法,不跟
/// `_buildMasterPane` 打架。位置用 `RenderBox.localToGlobal` 量一次
/// (悬浮期间气泡本身不会动,不需要每帧跟踪)。
class HoverPopupAnchor extends StatefulWidget {
  const HoverPopupAnchor({
    super.key,
    required this.child,
    required this.popupBuilder,
    required this.alignRight,
    this.gap = 8,
    this.canShow,
    this.estimatedWidth = 220,
  });

  final Widget child;
  final Widget Function(BuildContext context, VoidCallback closePopup) popupBuilder;
  final bool alignRight;
  final double gap;
  /// 返回 false 时不弹出(比如 reaction 没有 users 数据)
  final bool Function()? canShow;
  /// 弹层大概宽度,用来判断左对齐会不会超出屏幕右缘(自身消息靠右贴边
  /// 时,`alignRight: false` 硬左对齐会把弹层怼出屏幕外)。不用精确值,
  /// 够判断超没超就行。
  final double estimatedWidth;

  @override
  State<HoverPopupAnchor> createState() => HoverPopupAnchorState();
}

class HoverPopupAnchorState extends State<HoverPopupAnchor> {
  /// 同一时间全 App 只允许一个悬浮弹层开着——否则手速快的话可以在关闭
  /// 延迟(250ms)内连续划过好几条消息,叠出一堆同时开着的弹层。
  static HoverPopupAnchorState? _currentlyOpen;

  OverlayEntry? _entry;
  Timer? _closeTimer;
  bool _pointerOverAnchor = false;
  bool _pointerOverPopup = false;

  @override
  void dispose() {
    _closeTimer?.cancel();
    if (_currentlyOpen == this) _currentlyOpen = null;
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _cancelClose() => _closeTimer?.cancel();

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      if (!_pointerOverAnchor && !_pointerOverPopup) {
        if (_currentlyOpen == this) _currentlyOpen = null;
        _removeEntry();
      }
    });
  }

  void open() {
    if (_entry != null) return;
    if (widget.canShow != null && !widget.canShow!()) return;
    if (_currentlyOpen != null && _currentlyOpen != this) {
      _currentlyOpen!.closeNow();
    }
    _currentlyOpen = this;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    // 左对齐会超出屏幕右缘时(自身消息贴右边),改成右对齐——两边都超
    // (窗口特别窄)就还是保留左对齐,总要选一个,不然逻辑打架。
    final overlayWidth = overlayBox?.size.width ?? double.infinity;
    final wouldOverflowRight = topLeft.dx + widget.estimatedWidth > overlayWidth;
    final effectiveAlignRight = widget.alignRight || wouldOverflowRight;

    _entry = OverlayEntry(
      builder: (overlayCtx) => Positioned(
        left: effectiveAlignRight ? null : topLeft.dx,
        right: effectiveAlignRight
            ? (overlayBox?.size.width ?? 0) - (topLeft.dx + size.width)
            : null,
        top: topLeft.dy,
        child: FractionalTranslation(
          translation: const Offset(0, -1),
          child: Transform.translate(
            offset: Offset(0, -widget.gap),
            child: MouseRegion(
              onEnter: (_) {
                _pointerOverPopup = true;
                _cancelClose();
              },
              onExit: (_) {
                _pointerOverPopup = false;
                _scheduleClose();
              },
              // 点悬浮条上任意一个按钮(比如"更多"打开底部菜单)之后,
              // 悬浮条本身也该跟着收起,不然它会悬在打开的菜单/弹窗后面。
              child: widget.popupBuilder(overlayCtx, closeNow),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void closeNow() {
    _closeTimer?.cancel();
    if (_currentlyOpen == this) _currentlyOpen = null;
    _removeEntry();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        _pointerOverAnchor = true;
        _cancelClose();
        open();
      },
      onExit: (_) {
        _pointerOverAnchor = false;
        _scheduleClose();
      },
      child: widget.child,
    );
  }
}

/// 点击触发、贴在点击位置正上方(空间不够时自动翻到下方)的锚定弹层。
/// 用于表情选择器这类"点了才开、选完/点外面/一滚动就该关"的场景——
/// 不用 [showMenu]:它的 PopupMenuRoute 自带半透明遮罩(挡住背景整个区域,
/// 看起来像一大片阴影)且只会挑"哪边放得下"而不是优先贴在按钮正上方。
/// 这里手动 [OverlayEntry] 全权控制:无遮罩、显式上下优先、滚动监听里
/// 直接关闭。
Future<T?> showAnchoredPopup<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required Widget Function(BuildContext ctx, void Function(T? result) close)
      builder,
  ScrollController? closeOnScroll,
  double gap = 8,
  double panelWidth = 340,
  double panelHeight = 400,
}) {
  final btnBox = anchorContext.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  if (btnBox == null || !btnBox.hasSize || overlayBox == null) {
    return Future.value(null);
  }
  final anchorTopLeft = btnBox.localToGlobal(Offset.zero, ancestor: overlayBox);
  final anchorSize = btnBox.size;
  final overlaySize = overlayBox.size;

  final completer = Completer<T?>();
  OverlayEntry? entry;
  bool closed = false;

  void close(T? result) {
    if (closed) return;
    closed = true;
    entry?.remove();
    if (!completer.isCompleted) completer.complete(result);
  }

  // 优先贴上方(悬浮条按钮上方够放才这么摆);上方空间不够就翻到下方。
  final spaceAbove = anchorTopLeft.dy;
  final placeAbove = spaceAbove >= panelHeight + gap;
  final top = placeAbove
      ? anchorTopLeft.dy - panelHeight - gap
      : anchorTopLeft.dy + anchorSize.height + gap;

  // 水平方向贴锚点左边对齐,超出屏幕右缘就整体左移贴屏幕边缘。
  var left = anchorTopLeft.dx;
  if (left + panelWidth > overlaySize.width) {
    left = (overlaySize.width - panelWidth - 8).clamp(8, overlaySize.width);
  }

  void onScroll() => close(null);
  closeOnScroll?.addListener(onScroll);

  entry = OverlayEntry(
    builder: (overlayCtx) => Stack(
      children: [
        // 透明点击外部关闭层
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => close(null),
          ),
        ),
        Positioned(
          left: left,
          top: top.clamp(8, overlaySize.height - panelHeight - 8),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: panelWidth,
              height: panelHeight,
              child: builder(overlayCtx, close),
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);

  completer.future.whenComplete(() {
    closeOnScroll?.removeListener(onScroll);
  });
  return completer.future;
}
