import 'package:common_ui/common_ui.dart' show UiShapesContext;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'm3e_flags.dart';
import 'm3e_motion.dart';

class M3eFabMenuItem {
  const M3eFabMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Widget icon;
  final Widget label;
  final VoidCallback onPressed;
}

bool _animateMenu(BuildContext context) =>
    M3eFlags.of(context).enabled &&
    !MediaQuery.disableAnimationsOf(context) &&
    !MediaQuery.reduceMotionOf(context);

/// 标准尺寸的菜单开关。可与 [M3eFabMenuItems] 分别放在锚点与浮层内。
class M3eFabMenuButton extends StatefulWidget {
  const M3eFabMenuButton({
    super.key,
    required this.expanded,
    required this.icon,
    required this.onPressed,
    this.closeIcon = const Icon(Icons.close),
    this.tooltip,
    this.focusNode,
  });

  final bool expanded;
  final Widget icon;
  final Widget closeIcon;
  final VoidCallback onPressed;
  final String? tooltip;
  final FocusNode? focusNode;

  @override
  State<M3eFabMenuButton> createState() => _FabMenuButtonState();
}

class _FabMenuButtonState extends State<M3eFabMenuButton>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController.unbounded(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );

  @override
  void didUpdateWidget(M3eFabMenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      final target = widget.expanded ? 1.0 : 0.0;
      if (_animateMenu(context)) {
        M3eMotion.fastSpatial.animateTo(_progress, target);
      } else {
        _progress.value = target;
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_animateMenu(context)) _progress.value = widget.expanded ? 1 : 0;
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return FloatingActionButton(
        heroTag: null,
        onPressed: widget.onPressed,
        focusNode: widget.focusNode,
        tooltip: widget.tooltip,
        child: widget.expanded ? widget.closeIcon : widget.icon,
      );
    }
    final theme = Theme.of(context);
    final fab = theme.floatingActionButtonTheme;
    final scheme = theme.colorScheme;
    final initialShape =
        fab.shape ??
        RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(16),
        );
    final finalShape = context.shapes.circle();
    final button = AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final progress = _progress.value;
        final tint = progress.clamp(0.0, 1.0);
        final foreground =
            fab.foregroundColor ??
            Color.lerp(scheme.onPrimaryContainer, scheme.onPrimary, tint)!;
        final elevation = fab.elevation ?? 6.0;
        return RawMaterialButton(
          constraints: const BoxConstraints.tightFor(width: 56, height: 56),
          animationDuration: Duration.zero,
          shape: ShapeBorder.lerp(initialShape, finalShape, tint)!,
          fillColor:
              fab.backgroundColor ??
              Color.lerp(scheme.primaryContainer, scheme.primary, tint),
          elevation: elevation,
          focusElevation: fab.focusElevation ?? elevation,
          hoverElevation: fab.hoverElevation ?? elevation,
          highlightElevation: fab.highlightElevation ?? elevation,
          clipBehavior: Clip.antiAlias,
          focusNode: widget.focusNode,
          onPressed: widget.onPressed,
          focusColor: fab.focusColor,
          hoverColor: fab.hoverColor,
          splashColor: fab.splashColor,
          enableFeedback: fab.enableFeedback ?? true,
          child: IconTheme.merge(
            data: IconThemeData(size: 24 - 4 * progress, color: foreground),
            child: progress > 0.5 ? widget.closeIcon : widget.icon,
          ),
        );
      },
    );
    return Semantics(
      button: true,
      expanded: widget.expanded,
      child: widget.tooltip == null
          ? button
          : Tooltip(message: widget.tooltip!, child: button),
    );
  }
}

/// 从靠近 FAB 的一项开始展开，收起时逆序。每项在原位展开宽度和透明度。
class M3eFabMenuItems extends StatefulWidget {
  const M3eFabMenuItems({
    super.key,
    required this.expanded,
    required this.items,
    this.onDismissed,
    this.iconAlignment = IconAlignment.start,
  });

  final bool expanded;
  final List<M3eFabMenuItem> items;
  final VoidCallback? onDismissed;
  final IconAlignment iconAlignment;

  @override
  State<M3eFabMenuItems> createState() => _FabMenuItemsState();
}

class _FabMenuItemsState extends State<M3eFabMenuItems>
    with TickerProviderStateMixin {
  late final _stagger = AnimationController.unbounded(vsync: this)
    ..addListener(_updateItems);
  final _motions = <_FabItemMotion>[];
  bool? _animate;
  bool _dismissed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = _animateMenu(context);
    if (_animate == animate) return;
    _animate = animate;
    _sync();
  }

  @override
  void didUpdateWidget(M3eFabMenuItems oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded ||
        widget.items.length != oldWidget.items.length) {
      _sync();
    }
  }

  void _sync() {
    while (_motions.length > widget.items.length) {
      _motions.removeLast().dispose();
    }
    while (_motions.length < widget.items.length) {
      _motions.add(_FabItemMotion(this, _checkDismissed));
    }
    if (widget.expanded) _dismissed = false;
    final target = widget.expanded ? _motions.length.toDouble() : 0.0;
    if (_animate! && (_stagger.isAnimating || _stagger.value != target)) {
      M3eMotion.slowEffects.animateTo(_stagger, target);
    } else {
      _stagger.value = target;
    }
    _updateItems();
  }

  void _updateItems() {
    final count = _stagger.value.round().clamp(0, _motions.length);
    for (var index = 0; index < _motions.length; index++) {
      _motions[index].show(index < count, animate: _animate!);
    }
    _checkDismissed();
  }

  void _checkDismissed() {
    if (widget.expanded ||
        _dismissed ||
        _motions.any((motion) => motion.visible || motion.alpha.value > 0)) {
      return;
    }
    _dismissed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _dismissed && !widget.expanded) widget.onDismissed?.call();
    });
  }

  @override
  void dispose() {
    _stagger.dispose();
    for (final motion in _motions) {
      motion.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fab = theme.floatingActionButtonTheme;
    final style = FilledButton.styleFrom(
      backgroundColor:
          fab.backgroundColor ?? theme.colorScheme.primaryContainer,
      foregroundColor:
          fab.foregroundColor ?? theme.colorScheme.onPrimaryContainer,
      minimumSize: const Size(0, 56),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      spacing: 4,
      children: [
        for (final (index, item) in widget.items.indexed)
          _buildItem(item, _motions[_motions.length - 1 - index], style),
      ],
    );
  }

  Widget _buildItem(
    M3eFabMenuItem item,
    _FabItemMotion motion,
    ButtonStyle style,
  ) {
    final label = Flexible(child: item.label);
    return AnimatedBuilder(
      animation: motion.changes,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: widget.iconAlignment == IconAlignment.start
              ? [item.icon, label]
              : [label, item.icon],
        ),
      ),
      builder: (context, content) {
        final interactive =
            widget.expanded && motion.visible && motion.alpha.value > 0;
        return IgnorePointer(
          ignoring: !interactive,
          child: ExcludeFocus(
            excluding: !interactive,
            child: ExcludeSemantics(
              excluding: !interactive,
              child: Opacity(
                opacity: motion.alpha.value.clamp(0.0, 1.0),
                child: FilledButton(
                  style: style,
                  clipBehavior: Clip.antiAlias,
                  onPressed: item.onPressed,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    widthFactor: motion.width.value.clamp(0.0, double.infinity),
                    heightFactor: 1,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FabItemMotion {
  _FabItemMotion(TickerProvider vsync, VoidCallback onAlphaChanged)
    : width = AnimationController.unbounded(vsync: vsync),
      alpha = AnimationController.unbounded(vsync: vsync)
        ..addListener(onAlphaChanged);

  final AnimationController width;
  final AnimationController alpha;
  late final Listenable changes = Listenable.merge([width, alpha]);
  bool visible = false;

  void show(bool value, {required bool animate}) {
    if (animate && visible == value) return;
    visible = value;
    final target = value ? 1.0 : 0.0;
    if (animate) {
      M3eMotion.fastSpatial.animateTo(width, target);
      M3eMotion.fastEffects.animateTo(alpha, target);
    } else {
      width.value = target;
      alpha.value = target;
    }
  }

  void dispose() {
    width.dispose();
    alpha.dispose();
  }
}

class M3eFabMenu extends StatefulWidget {
  const M3eFabMenu({
    super.key,
    required this.icon,
    required this.items,
    this.onPressed,
  });

  final Widget icon;
  final List<M3eFabMenuItem> items;
  final VoidCallback? onPressed;

  @override
  State<M3eFabMenu> createState() => M3eFabMenuState();
}

class M3eFabMenuState extends State<M3eFabMenu> {
  bool _open = false;
  bool _showItems = false;

  bool get isOpen => _open;

  void toggle() {
    setState(() {
      _open = !_open;
      if (_open) _showItems = true;
    });
    if (_open) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
  }

  void close() {
    if (_open) toggle();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return FloatingActionButton(
        onPressed: widget.onPressed,
        child: widget.icon,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      spacing: 8,
      children: [
        if (_showItems)
          M3eFabMenuItems(
            expanded: _open,
            onDismissed: () => setState(() => _showItems = false),
            items: [
              for (final item in widget.items)
                M3eFabMenuItem(
                  icon: item.icon,
                  label: item.label,
                  onPressed: () {
                    close();
                    item.onPressed();
                  },
                ),
            ],
          ),
        M3eFabMenuButton(expanded: _open, icon: widget.icon, onPressed: toggle),
      ],
    );
  }
}
