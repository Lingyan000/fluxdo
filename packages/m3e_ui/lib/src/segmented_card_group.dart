import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart' show UiShapesContext;

import 'm3e_flags.dart';
import 'segmented_card_style.dart';

/// M3 Expressive 风格分段卡片组
///
/// 参照最新 Material 3 Expressive 列表规范（Chrome / Android 系统设置）：
/// 每个条目独立成块，组首/组尾用大圆角、相邻处用小圆角，块间以细缝分隔，
/// 取代旧式「整卡 + Divider」布局。
class SegmentedCardGroup extends StatefulWidget {
  final List<Widget> children;

  /// 组首/组尾的大圆角设计值，按当前 UiShapes 换算。
  final double outerRadius;

  /// 相邻条目之间的小圆角设计值，按当前 UiShapes 换算。
  final double innerRadius;

  /// 条目间距
  final double gap;

  /// 块背景色，默认跟随 cardTheme（surfaceContainerLow）
  final Color? color;

  const SegmentedCardGroup({
    super.key,
    required this.children,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.gap = 3,
    this.color,
    this.animateChanges = true,
  });

  /// 有稳定 key 的行增删时展开/收起。无 key 的旧调用保留即时布局。
  final bool animateChanges;

  @override
  State<SegmentedCardGroup> createState() => _SegmentedCardGroupState();
}

class _CardEntry {
  _CardEntry(this.key, this.child, {this.entering = false});
  final Key key;
  Widget child;
  bool entering;
  bool leaving = false;
  int index = 0;
  int count = 1;
}

class _SegmentedCardGroupState extends State<SegmentedCardGroup> {
  List<_CardEntry> _entries = [];
  bool _motionEnabled = false;
  bool get _animate => widget.animateChanges && _keyed && _motionEnabled;

  bool get _keyed =>
      widget.children.every((child) => child.key != null) &&
      widget.children.map((child) => child.key).toSet().length ==
          widget.children.length;

  @override
  void initState() {
    super.initState();
    _replace();
  }

  void _replace() {
    _entries = [
      for (final (index, child) in widget.children.indexed)
        _CardEntry(child.key ?? ValueKey(index), child)
          ..index = index
          ..count = widget.children.length,
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        M3eFlags.of(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (!_animate) _replace();
  }

  @override
  void didUpdateWidget(SegmentedCardGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_animate ||
        !widget.animateChanges ||
        !_keyed ||
        (widget.children.length - oldWidget.children.length).abs() > 20) {
      _replace();
      return;
    }
    final old = {for (final entry in _entries) entry.key: entry};
    final wanted = widget.children.map((child) => child.key).toSet();
    // 退场行留在原有相邻行之前，收起过程不会先跳到列表尾部。
    final before = <Key, List<_CardEntry>>{};
    var pending = <_CardEntry>[];
    for (final entry in _entries) {
      if (wanted.contains(entry.key)) {
        before[entry.key] = pending;
        pending = [];
      } else {
        entry.leaving = true;
        pending.add(entry);
      }
    }
    final next = <_CardEntry>[];
    for (final (index, child) in widget.children.indexed) {
      final key = child.key!;
      next.addAll(before[key] ?? []);
      final entry = old[key] ?? _CardEntry(key, child, entering: true);
      entry
        ..child = child
        ..leaving = false
        ..index = index
        ..count = widget.children.length;
      next.add(entry);
    }
    _entries = [...next, ...pending];
  }

  @override
  Widget build(BuildContext context) {
    final style = SegmentedCardStyle.of(context);
    if (style.mode != SegmentedCardMode.segmented) {
      return _buildLined(context, style);
    }
    return Column(
      children: [
        for (final entry in _entries)
          _CardPresence(
            key: ValueKey(entry.key),
            visible: !entry.leaving,
            enter: entry.entering,
            animate: _animate,
            onHidden: () {
              if (mounted && entry.leaving) {
                setState(() => _entries.remove(entry));
              }
            },
            child: Padding(
              padding: EdgeInsets.only(top: entry.index > 0 ? widget.gap : 0),
              child: SegmentedCardItem(
                index: entry.index,
                count: entry.count,
                outerRadius: widget.outerRadius,
                innerRadius: widget.innerRadius,
                color: widget.color,
                child: entry.child,
              ),
            ),
          ),
      ],
    );
  }
}

extension on _SegmentedCardGroupState {
  /// 描边 / 平铺：条目之间画细线（不留缝），描边模式外加整组细线框。
  /// 条目增删的展开收起动画与分段模式共用 [_CardPresence]。
  Widget _buildLined(BuildContext context, SegmentedCardStyle style) {
    final scheme = Theme.of(context).colorScheme;
    final divider = style.dividerColor ?? scheme.outlineVariant;
    final outlined = style.mode == SegmentedCardMode.outlined;
    final column = Column(
      children: [
        for (final entry in _entries)
          _CardPresence(
            key: ValueKey(entry.key),
            visible: !entry.leaving,
            enter: entry.entering,
            animate: _animate,
            onHidden: () {
              if (mounted && entry.leaving) {
                // ignore: invalid_use_of_protected_member
                setState(() => _entries.remove(entry));
              }
            },
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: entry.index > 0
                    ? Border(top: BorderSide(color: divider, width: 0.6))
                    : null,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: entry.child,
              ),
            ),
          ),
      ],
    );
    if (!outlined) return column;
    return Material(
      color: widget.color ?? style.background ?? scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(widget.outerRadius),
        side: BorderSide(
          color: style.borderColor ?? scheme.outlineVariant,
        ),
      ),
      child: column,
    );
  }
}

class _CardPresence extends StatefulWidget {
  const _CardPresence({
    super.key,
    required this.visible,
    required this.enter,
    required this.animate,
    required this.onHidden,
    required this.child,
  });
  final bool visible;
  final bool enter;
  final bool animate;
  final VoidCallback onHidden;
  final Widget child;
  @override
  State<_CardPresence> createState() => _CardPresenceState();
}

class _CardPresenceState extends State<_CardPresence>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.enter && widget.animate ? 0 : 1,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !widget.visible) widget.onHidden();
        });
      }
    });
    if (widget.visible && _controller.value < 1) _controller.forward();
  }

  @override
  void didUpdateWidget(_CardPresence oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animate) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible != oldWidget.visible) {
      widget.visible ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: ExcludeFocus(
      excluding: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: SizeTransition(
          sizeFactor: _curve,
          alignment: Alignment.topCenter,
          child: FadeTransition(opacity: _curve, child: widget.child),
        ),
      ),
    ),
  );
}

/// 分段卡片组中的单个条目块
///
/// 根据 [index] / [count] 决定上下圆角，并按主题的 [SegmentedCardStyle]
/// 呈现：分段模式为独立色块，描边模式为整组细线框里的一段，平铺模式不画
/// 容器。[SegmentedCardGroup] 内部使用它；懒加载列表（ListView.builder）
/// 中也可直接按索引使用，各模式的外观与 [SegmentedCardGroup] 一致。
class SegmentedCardItem extends StatelessWidget {
  final int index;
  final int count;
  final double outerRadius;
  final double innerRadius;

  /// 底色（含选中、高亮等状态色）。缺省时分段模式取 cardTheme，描边模式
  /// 取 [SegmentedCardStyle.background]，平铺模式透明。
  final Color? color;

  /// 分段模式下与下一项的间距，画在条目下方；懒加载列表逐项使用时传入。
  /// 描边、平铺模式条目之间以细线分隔，不留缝（实际值见 [gapOf]）。
  final double gap;

  /// 叠在条目轮廓上的描边（例如选中态）
  final BorderSide side;

  final Widget child;

  const SegmentedCardItem({
    super.key,
    required this.index,
    required this.count,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.color,
    this.gap = 0,
    this.side = BorderSide.none,
    required this.child,
  });

  /// 当前模式下条目之间实际留出的间距。
  static double gapOf(BuildContext context, double gap) =>
      SegmentedCardStyle.of(context).mode == SegmentedCardMode.segmented
      ? gap
      : 0;

  /// 条目轮廓的圆角：内容自带按压、水波纹等效果时用它对齐形状。
  static BorderRadius borderRadiusOf(
    BuildContext context, {
    required int index,
    required int count,
    double outerRadius = 20,
    double innerRadius = 5,
  }) {
    final segmented =
        SegmentedCardStyle.of(context).mode == SegmentedCardMode.segmented;
    final inner = segmented ? innerRadius : 0.0;
    return BorderRadius.vertical(
      top: context.shapes.radius(index == 0 ? outerRadius : inner),
      bottom: context.shapes.radius(index == count - 1 ? outerRadius : inner),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = SegmentedCardStyle.of(context);
    final radius = borderRadiusOf(
      context,
      index: index,
      count: count,
      outerRadius: outerRadius,
      innerRadius: innerRadius,
    );
    final shape = RoundedSuperellipseBorder(borderRadius: radius, side: side);

    if (style.mode == SegmentedCardMode.segmented) {
      final item = Material(
        color: color ?? theme.cardTheme.color ?? scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: shape,
        child: child,
      );
      return index < count - 1 && gap > 0
          ? Padding(padding: EdgeInsets.only(bottom: gap), child: item)
          : item;
    }

    final outlined = style.mode == SegmentedCardMode.outlined;
    return CustomPaint(
      foregroundPainter: _LinedSegmentPainter(
        divider: index > 0 ? style.dividerColor ?? scheme.outlineVariant : null,
        outline: outlined ? style.borderColor ?? scheme.outlineVariant : null,
        first: index == 0,
        last: index == count - 1,
        radius: context.shapes.radius(outerRadius),
      ),
      child: Material(
        color:
            color ??
            (outlined ? style.background ?? scheme.surface : Colors.transparent),
        clipBehavior: Clip.antiAlias,
        shape: shape,
        child: child,
      ),
    );
  }
}

/// 描边 / 平铺模式下单个条目的线：顶部分隔线，以及整组外框落在本条目
/// 范围内的那一段（外框按整组形状绘制、裁剪到本条目，逐项拼起来就是
/// 一个连续的框）。
class _LinedSegmentPainter extends CustomPainter {
  _LinedSegmentPainter({
    required this.divider,
    required this.outline,
    required this.first,
    required this.last,
    required this.radius,
  });

  final Color? divider;
  final Color? outline;
  final bool first;
  final bool last;
  final Radius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final outline = this.outline;
    if (outline != null) {
      // 不是组首 / 组尾的一侧向外延伸一个圆角，圆角就落在本条目之外
      final reach = radius.y * 2 + 1;
      final frame = Rect.fromLTRB(
        0.5,
        first ? 0.5 : -reach,
        size.width - 0.5,
        last ? size.height - 0.5 : size.height + reach,
      );
      canvas
        ..save()
        ..clipRect(bounds)
        ..drawRSuperellipse(
          RSuperellipse.fromRectAndRadius(frame, radius),
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        )
        ..restore();
    }
    final divider = this.divider;
    if (divider != null) {
      canvas.drawLine(
        const Offset(0, 0.3),
        Offset(size.width, 0.3),
        Paint()
          ..color = divider
          ..strokeWidth = 0.6,
      );
    }
  }

  @override
  bool shouldRepaint(_LinedSegmentPainter old) =>
      old.divider != divider ||
      old.outline != outline ||
      old.first != first ||
      old.last != last ||
      old.radius != radius;
}
