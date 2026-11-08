import 'package:flutter/material.dart';

import 'm3e_flags.dart';

/// M3 Expressive 风格分段卡片组
///
/// 参照最新 Material 3 Expressive 列表规范（Chrome / Android 系统设置）：
/// 每个条目独立成块，组首/组尾用大圆角、相邻处用小圆角，块间以细缝分隔，
/// 取代旧式「整卡 + Divider」布局。
class SegmentedCardGroup extends StatefulWidget {
  final List<Widget> children;

  /// 组首/组尾的大圆角
  final double outerRadius;

  /// 相邻条目之间的小圆角
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
/// 根据 [index] / [count] 决定上下圆角。供 [SegmentedCardGroup] 内部使用；
/// 懒加载列表（ListView.builder）中也可直接按索引使用。
class SegmentedCardItem extends StatelessWidget {
  final int index;
  final int count;
  final double outerRadius;
  final double innerRadius;
  final Color? color;
  final Widget child;

  const SegmentedCardItem({
    super.key,
    required this.index,
    required this.count,
    this.outerRadius = 20,
    this.innerRadius = 5,
    this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background =
        color ?? theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;

    return Material(
      color: background,
      clipBehavior: Clip.antiAlias,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(index == 0 ? outerRadius : innerRadius),
          bottom: Radius.circular(
            index == count - 1 ? outerRadius : innerRadius,
          ),
        ),
      ),
      child: child,
    );
  }
}
