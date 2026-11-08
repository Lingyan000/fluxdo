import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'm3e_elastic_press.dart';
import 'm3e_flags.dart';

/// 一个联排按钮项。
class M3eButtonGroupItem<T> {
  final T value;
  final Widget label;
  final Widget? icon;

  const M3eButtonGroupItem({
    required this.value,
    required this.label,
    this.icon,
  });
}

/// M3E 联排选择按钮：选中项的圆角和底色连续变化，按住拖动时弹性拉伸。
///
/// 复用原有接口、字号与内边距；按压仅改变绘制，不挤压邻项或改变组的尺寸。
/// 关闭 M3E 时继续使用原生 [SegmentedButton]。
class M3eButtonGroup<T> extends StatefulWidget {
  final List<M3eButtonGroupItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry itemPadding;

  const M3eButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  @override
  State<M3eButtonGroup<T>> createState() => _M3eButtonGroupState<T>();
}

class _M3eButtonGroupState<T> extends State<M3eButtonGroup<T>> {
  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return SegmentedButton<T>(
        segments: [
          for (final item in widget.items)
            ButtonSegment<T>(
              value: item.value,
              label: item.label,
              icon: item.icon,
            ),
        ],
        selected: {widget.selected},
        onSelectionChanged: (values) => widget.onSelected(values.first),
        showSelectedIcon: false,
      );
    }
    return _ConnectedRow(
      children: [
        for (var i = 0; i < widget.items.length; i++)
          Expanded(
            key: ValueKey(widget.items[i].value),
            child: RawGestureDetector(
              excludeFromSemantics: true,
              gestures: {
                _ConnectedDragRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _ConnectedDragRecognizer
                    >(() => _ConnectedDragRecognizer(), (_) {}),
              },
              // 形变属于单个按钮，组容器和相邻按钮保持静止。
              child: M3eElasticPress(
                selectionFeedback: true,
                child: _ConnectedButton(
                  selected: widget.items[i].value == widget.selected,
                  first: i == 0,
                  last: i == widget.items.length - 1,
                  padding: widget.itemPadding,
                  icon: widget.items[i].icon,
                  label: widget.items[i].label,
                  onSelected: () => widget.onSelected(widget.items[i].value),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 最近按下的按钮最后绘制，膨胀边缘不会被相邻按钮遮住。
class _ConnectedRow extends Row {
  const _ConnectedRow({required super.children}) : super(spacing: 3);

  @override
  RenderFlex createRenderObject(BuildContext context) =>
      _ConnectedRenderRow(textDirection: Directionality.of(context));
}

class _ConnectedRenderRow extends RenderFlex {
  _ConnectedRenderRow({required TextDirection textDirection})
    : super(
        direction: Axis.horizontal,
        spacing: 3,
        textDirection: textDirection,
      );

  RenderBox? _raised;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is! PointerDownEvent || event.buttons != kPrimaryButton) return;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final offset = (child.parentData! as FlexParentData).offset;
      if ((offset & child.size).contains(entry.localPosition)) {
        _raised = child;
        markNeedsPaint();
        break;
      }
    }
  }

  @override
  void dropChild(RenderObject child) {
    if (identical(child, _raised)) _raised = null;
    super.dropChild(child);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    void paintChild(RenderBox child) => context.paintChild(
      child,
      offset + (child.parentData! as FlexParentData).offset,
    );
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (!identical(child, _raised)) paintChild(child);
    }
    if (_raised case final raised?) paintChild(raised);
  }
}

class _ConnectedButton extends StatelessWidget {
  const _ConnectedButton({
    required this.selected,
    required this.first,
    required this.last,
    required this.padding,
    required this.label,
    required this.icon,
    required this.onSelected,
  });
  final bool selected, first, last;
  final EdgeInsetsGeometry padding;
  final Widget label;
  final Widget? icon;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final direction = Directionality.of(context);
    final outer = math.max(
      24.0,
      (MediaQuery.textScalerOf(context).scale(20) +
              padding.resolve(direction).vertical) /
          2,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      builder: (context, amount, _) {
        final inner = 8 + (outer - 8) * amount;
        final shape = RoundedSuperellipseBorder(
          borderRadius: BorderRadiusDirectional.horizontal(
            start: Radius.circular(first ? outer : inner),
            end: Radius.circular(last ? outer : inner),
          ),
        );
        final foreground = Color.lerp(
          scheme.onSurfaceVariant,
          scheme.onPrimary,
          amount,
        )!;
        return Semantics(
          button: true,
          selected: selected,
          inMutuallyExclusiveGroup: true,
          child: Material(
            color: Color.lerp(
              scheme.surfaceContainerHigh,
              scheme.primary,
              amount,
            ),
            shape: shape,
            clipBehavior: Clip.antiAlias,
            animationDuration: Duration.zero,
            child: InkWell(
              customBorder: shape,
              onTap: onSelected,
              splashFactory: NoSplash.splashFactory,
              child: Padding(
                padding: padding,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      IconTheme.merge(
                        data: IconThemeData(size: 18, color: foreground),
                        child: icon!,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: DefaultTextStyle.merge(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.lerp(
                            FontWeight.w500,
                            FontWeight.w600,
                            amount,
                          ),
                          color: foreground,
                        ),
                        child: label,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 移动超过容差后赢得手势竞争，取消点击、父级滚动/翻页等竞争手势。
/// 未拖动的普通点击仍交给内部 InkWell，保留原回调与键盘语义。
class _ConnectedDragRecognizer extends OneSequenceGestureRecognizer {
  _ConnectedDragRecognizer();
  PointerDownEvent? _down;
  bool _dragging = false;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _down == null &&
      event.buttons == kPrimaryButton &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down = event;
    _dragging = false;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (down == null || event.pointer != down.pointer) return;
    if (event is PointerMoveEvent) {
      if (!_dragging &&
          (event.position - down.position).distance >
              computeHitSlop(event.kind, gestureSettings)) {
        resolve(GestureDisposition.accepted);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      final dragging = _dragging;
      _down = null;

      if (!dragging) resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_down?.pointer == pointer) _dragging = true;
  }

  @override
  void rejectGesture(int pointer) {
    if (_down?.pointer != pointer) return;
    _down = null;
    _dragging = false;
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
  @override
  String get debugDescription => 'connected button drag';
}
