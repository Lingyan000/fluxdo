import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'route_interaction.dart';
import 'ui_emphasis.dart';
import 'ui_shapes.dart';

/// [AppDropdown] 与 [AppDropdownFormField] 的单个选项描述。
class AppDropdownItem<T> {
  const AppDropdownItem({
    required this.value,
    required this.label,
    this.child,
    this.subtitle,
    this.leading,
    this.enabled = true,
  });

  final T value;

  /// 选项主文案，用于语义、展示及缺省触发器显示。
  final String label;

  /// 自定义选项主内容；为空时渲染 [label]。
  final Widget? child;

  /// 可选次要说明文案（仅在下拉浮层中展示）。
  final String? subtitle;

  /// 可选前置图标或徽标。
  final Widget? leading;

  /// 是否允许选择。
  final bool enabled;
}

/// 现代附着式下拉选择控件。
///
/// 结合 M3E 选择菜单与主题令牌：
/// - 传入 [decoration] 时自动接入 [InputDecorationTheme]，与页面内的输入框共享
///   填充、描边、下划线与聚焦高亮；
/// - 未传入 [decoration] 时以柔和胶囊/圆角触发器呈现，适合工具栏与表单行内；
/// - 展开菜单贴合触发框上下翻转，使用同心超椭圆圆角、选中胶囊高亮与勾选标记、
///   弹簧展开动效、滑动空白处即刻关闭以及键盘方向键导航。
class AppDropdown<T> extends StatefulWidget {
  const AppDropdown({
    super.key,
    required this.items,
    this.value,
    this.onChanged,
    this.hint,
    this.decoration,
    this.isExpanded = false,
    this.isDense = false,
    this.compact = false,
    this.enabled = true,
    this.menuMaxHeight = 320,
    this.menuMinWidth,
    this.menuMaxWidth,
    this.selectedItemBuilder,
    this.focusNode,
    this.tooltip,
    this.icon,
  });

  final List<AppDropdownItem<T>> items;
  final T? value;
  final ValueChanged<T?>? onChanged;

  /// 未选中值时的占位提示。
  final String? hint;

  /// 表单输入框装饰；传入时按 [InputDecorator] 渲染。
  final InputDecoration? decoration;

  /// 是否横向撑满父容器。传入 [decoration] 时默认撑满。
  final bool isExpanded;

  /// 紧凑纵向内边距。
  final bool isDense;

  /// 轻量触发器外观（透明底，仅悬停/聚焦/展开时浮现底色，适合工具栏与筛选行）。
  final bool compact;

  final bool enabled;
  final double menuMaxHeight;
  final double? menuMinWidth;
  final double? menuMaxWidth;
  final Widget Function(BuildContext context, AppDropdownItem<T> item)?
  selectedItemBuilder;
  final FocusNode? focusNode;
  final String? tooltip;
  final IconData? icon;

  @override
  State<AppDropdown<T>> createState() => _AppDropdownState<T>();
}

class _AppDropdownState<T> extends State<AppDropdown<T>> {
  final GlobalKey _triggerKey = GlobalKey();
  FocusNode? _internalFocusNode;
  bool _isOpen = false;
  bool _hovered = false;
  bool _focused = false;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  bool get _isInteractive => widget.enabled && widget.onChanged != null;

  bool get _isFieldMode => widget.decoration != null;

  AppDropdownItem<T>? get _selectedItem {
    for (final item in widget.items) {
      if (item.value == widget.value) return item;
    }
    return null;
  }

  int get _selectedIndex {
    for (var i = 0; i < widget.items.length; i++) {
      if (widget.items[i].value == widget.value) return i;
    }
    return -1;
  }

  @override
  void initState() {
    super.initState();
    _effectiveFocusNode.addListener(_onFocusChanged);
    _focused = _effectiveFocusNode.hasFocus;
  }

  @override
  void didUpdateWidget(AppDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _internalFocusNode)?.removeListener(
        _onFocusChanged,
      );
      _effectiveFocusNode.addListener(_onFocusChanged);
      _focused = _effectiveFocusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    (widget.focusNode ?? _internalFocusNode)?.removeListener(_onFocusChanged);
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final hasFocus = _effectiveFocusNode.hasFocus;
    if (hasFocus != _focused) {
      setState(() => _focused = hasFocus);
    }
  }

  Future<void> _openMenu() async {
    if (!_isInteractive || _isOpen || widget.items.isEmpty) return;
    final triggerContext = _triggerKey.currentContext;
    if (triggerContext == null) return;
    final triggerBox = triggerContext.findRenderObject() as RenderBox?;
    final navigator = Navigator.of(context);
    final overlayBox =
        navigator.overlay?.context.findRenderObject() as RenderBox?;
    if (triggerBox == null || overlayBox == null || !triggerBox.hasSize) return;

    final topLeft = triggerBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final triggerRect = topLeft & triggerBox.size;

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isOpen = true);

    final result = await navigator.push<_DropdownResult<T>>(
      _AppDropdownRoute<T>(
        items: widget.items,
        selectedValue: widget.value,
        selectedIndex: _selectedIndex,
        triggerRect: triggerRect,
        matchTriggerWidth: _isFieldMode || widget.isExpanded,
        menuMaxHeight: widget.menuMaxHeight,
        menuMinWidth: widget.menuMinWidth,
        menuMaxWidth: widget.menuMaxWidth,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      ),
    );

    if (!mounted) return;
    setState(() => _isOpen = false);

    if (result != null) {
      widget.onChanged?.call(result.value);
    }
  }

  Widget _buildValueContent(BuildContext context, AppDropdownItem<T>? selected) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textStyle = (widget.compact
            ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)
            : theme.textTheme.bodyLarge ?? theme.textTheme.bodyMedium)
        ?.copyWith(
          color: _isInteractive
              ? cs.onSurface
              : cs.onSurface.withValues(alpha: 0.38),
        );

    if (selected == null) {
      final placeholder = widget.hint ?? widget.decoration?.hintText;
      if (placeholder == null) return const SizedBox.shrink();
      return Text(
        placeholder,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textStyle?.copyWith(
          color: _isInteractive
              ? cs.onSurfaceVariant.withValues(alpha: 0.72)
              : cs.onSurface.withValues(alpha: 0.38),
          fontWeight: FontWeight.w400,
        ),
      );
    }

    if (widget.selectedItemBuilder != null) {
      return DefaultTextStyle.merge(
        style: textStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: widget.selectedItemBuilder!(context, selected),
      );
    }

    final Widget label = selected.child != null
        ? DefaultTextStyle.merge(
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: selected.child!,
          )
        : Text(
            selected.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          );

    if (selected.leading == null) return label;
    return Row(
      mainAxisSize: widget.isExpanded || _isFieldMode
          ? MainAxisSize.max
          : MainAxisSize.min,
      children: [
        IconTheme.merge(
          data: IconThemeData(
            size: 18,
            color: _isInteractive
                ? cs.onSurfaceVariant
                : cs.onSurface.withValues(alpha: 0.38),
          ),
          child: selected.leading!,
        ),
        const SizedBox(width: 8),
        Flexible(child: label),
      ],
    );
  }

  Widget _buildChevron(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    final icon = Icon(
      widget.icon ?? Symbols.keyboard_arrow_down_rounded,
      size: widget.compact ? 18 : 20,
      color: !_isInteractive
          ? cs.onSurface.withValues(alpha: 0.38)
          : _isOpen
          ? context.emphasis.selected
          : cs.onSurfaceVariant,
    );
    if (reduceMotion) {
      return Transform.rotate(angle: _isOpen ? math.pi : 0, child: icon);
    }
    return AnimatedRotation(
      turns: _isOpen ? 0.5 : 0.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: icon,
    );
  }

  Widget _buildFieldTrigger(
    BuildContext context,
    AppDropdownItem<T>? selected,
  ) {
    final theme = Theme.of(context);
    final baseDeco = widget.decoration!;
    final effectiveDeco = baseDeco
        .applyDefaults(theme.inputDecorationTheme)
        .copyWith(
          enabled: _isInteractive,
          isDense: baseDeco.isDense ?? widget.isDense,
          // 下拉字段自己渲染占位文本，避免与 InputDecorator hint 重复叠层
          hintText: selected == null ? null : baseDeco.hintText,
        );

    final bool isEmpty = selected == null && widget.hint == null;
    final shape = RoundedSuperellipseBorder(
      borderRadius: context.shapes.borderRadius(12),
    );

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: _isInteractive ? _openMenu : null,
        customBorder: shape,
        canRequestFocus: false,
        child: InputDecorator(
          decoration: effectiveDeco,
          isFocused: _isOpen || _focused,
          isHovering: _hovered && _isInteractive,
          isEmpty: isEmpty,
          child: Row(
            children: [
              Expanded(child: _buildValueContent(context, selected)),
              const SizedBox(width: 6),
              _buildChevron(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStandaloneTrigger(
    BuildContext context,
    AppDropdownItem<T>? selected,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final inputTheme = theme.inputDecorationTheme;
    final isDark = theme.brightness == Brightness.dark;
    final bool isOutlineStyle =
        inputTheme.filled == false &&
        inputTheme.enabledBorder is! UnderlineInputBorder &&
        inputTheme.enabledBorder != null &&
        inputTheme.enabledBorder != InputBorder.none;
    final bool isUnderlineStyle =
        inputTheme.filled == false &&
        inputTheme.enabledBorder is UnderlineInputBorder;

    final double radiusValue = widget.compact ? 10 : 12;
    final BorderRadius borderRadius = context.shapes.borderRadius(radiusValue);

    Color fillColor;
    if (widget.compact) {
      if (_isOpen) {
        fillColor = cs.onSurface.withValues(alpha: isDark ? 0.12 : 0.08);
      } else if (_hovered && _isInteractive) {
        fillColor = cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.05);
      } else {
        fillColor = Colors.transparent;
      }
    } else if (isOutlineStyle || isUnderlineStyle) {
      fillColor = _isOpen || (_hovered && _isInteractive)
          ? cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04)
          : Colors.transparent;
    } else {
      if (!_isInteractive) {
        fillColor = cs.onSurface.withValues(alpha: 0.03);
      } else if (_isOpen || _hovered) {
        fillColor = cs.onSurface.withValues(alpha: isDark ? 0.10 : 0.08);
      } else {
        fillColor = cs.onSurface.withValues(alpha: isDark ? 0.07 : 0.055);
      }
    }

    BorderSide side;
    if (widget.compact) {
      side = _isOpen || _focused
          ? BorderSide(
              color: context.emphasis.selected.withValues(alpha: 0.5),
              width: 1.2,
            )
          : BorderSide.none;
    } else if (_isOpen || _focused) {
      side = BorderSide(color: context.emphasis.selected, width: 1.5);
    } else if (isOutlineStyle) {
      side = BorderSide(color: cs.outlineVariant);
    } else {
      side = BorderSide.none;
    }

    final fillShape = RoundedSuperellipseBorder(borderRadius: borderRadius);
    final borderShape = RoundedSuperellipseBorder(
      borderRadius: borderRadius,
      side: side,
    );

    final EdgeInsetsGeometry padding = widget.compact
        ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
        : widget.isDense
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 10);

    final content = Row(
      mainAxisSize: widget.isExpanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (widget.isExpanded)
          Expanded(child: _buildValueContent(context, selected))
        else
          Flexible(child: _buildValueContent(context, selected)),
        SizedBox(width: widget.compact ? 4 : 8),
        _buildChevron(context),
      ],
    );

    // 边框必须画在 foregroundDecoration 而非 decoration：Container 会把
    // decoration.padding（即 BorderSide.width）累加进内边距，导致展开/聚焦时
    // 边框宽度从 0 变到 1.5 撑大触发器，进而引起自适应高度的 BottomSheet 抖动。
    final Decoration foregroundDecoration = isUnderlineStyle && !widget.compact
        ? BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: _isOpen || _focused
                    ? context.emphasis.selected
                    : cs.outline,
                width: _isOpen || _focused ? 1.5 : 1,
              ),
            ),
          )
        : ShapeDecoration(shape: borderShape);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: ShapeDecoration(color: fillColor, shape: fillShape),
      foregroundDecoration: foregroundDecoration,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: _isInteractive ? _openMenu : null,
          customBorder: fillShape,
          canRequestFocus: false,
          child: Padding(padding: padding, child: content),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedItem;
    Widget trigger = KeyedSubtree(
      key: _triggerKey,
      child: _isFieldMode
          ? _buildFieldTrigger(context, selected)
          : _buildStandaloneTrigger(context, selected),
    );

    trigger = FocusableActionDetector(
      focusNode: _effectiveFocusNode,
      enabled: _isInteractive,
      onShowHoverHighlight: (hovered) {
        if (hovered != _hovered) setState(() => _hovered = hovered);
      },
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _openMenu();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: _isInteractive,
        expanded: _isOpen,
        label: widget.decoration?.labelText ?? widget.hint,
        value: selected?.label,
        child: trigger,
      ),
    );

    if (widget.tooltip != null) {
      trigger = Tooltip(message: widget.tooltip!, child: trigger);
    }
    return trigger;
  }
}

/// 表单集成版下拉选择框，直接替代原生 [DropdownButtonFormField]。
class AppDropdownFormField<T> extends FormField<T> {
  AppDropdownFormField({
    super.key,
    required this.items,
    super.initialValue,
    this.onChanged,
    this.decoration = const InputDecoration(),
    this.hint,
    this.isExpanded = true,
    this.isDense = false,
    this.menuMaxHeight = 320,
    this.selectedItemBuilder,
    this.focusNode,
    super.onSaved,
    super.validator,
    super.autovalidateMode,
    super.enabled = true,
    super.restorationId,
  }) : super(
         builder: (FormFieldState<T> field) {
           final state = field as _AppDropdownFormFieldState<T>;
           final effectiveDecoration = decoration.copyWith(
             errorText: field.errorText,
           );
           return AppDropdown<T>(
             items: items,
             value: field.value,
             onChanged: enabled
                 ? (T? value) {
                     state.didChange(value);
                     onChanged?.call(value);
                   }
                 : null,
             decoration: effectiveDecoration,
             hint: hint,
             isExpanded: isExpanded,
             isDense: isDense,
             enabled: enabled,
             menuMaxHeight: menuMaxHeight,
             selectedItemBuilder: selectedItemBuilder,
             focusNode: focusNode,
           );
         },
       );

  final List<AppDropdownItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration decoration;
  final String? hint;
  final bool isExpanded;
  final bool isDense;
  final double menuMaxHeight;
  final Widget Function(BuildContext context, AppDropdownItem<T> item)?
  selectedItemBuilder;
  final FocusNode? focusNode;

  @override
  FormFieldState<T> createState() => _AppDropdownFormFieldState<T>();
}

class _AppDropdownFormFieldState<T> extends FormFieldState<T> {
  @override
  AppDropdownFormField<T> get widget => super.widget as AppDropdownFormField<T>;

  @override
  void didUpdateWidget(AppDropdownFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue &&
        widget.initialValue != value) {
      setValue(widget.initialValue);
    }
  }
}

/// 包装选中值，区分「选中 null 选项」与「取消关闭（返回 null）」。
class _DropdownResult<T> {
  const _DropdownResult(this.value);
  final T? value;
}

class _AppDropdownRoute<T> extends PopupRoute<_DropdownResult<T>>
    with InterruptibleRoute<_DropdownResult<T>> {
  _AppDropdownRoute({
    required this.items,
    required this.selectedValue,
    required this.selectedIndex,
    required this.triggerRect,
    required this.matchTriggerWidth,
    required this.menuMaxHeight,
    required this.menuMinWidth,
    required this.menuMaxWidth,
    required this.capturedThemes,
    required this.barrierLabel,
  });

  final List<AppDropdownItem<T>> items;
  final T? selectedValue;
  final int selectedIndex;
  final Rect triggerRect;
  final bool matchTriggerWidth;
  final double menuMaxHeight;
  final double? menuMinWidth;
  final double? menuMaxWidth;
  final CapturedThemes capturedThemes;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  // M3E 临界阻尼弹簧曲线，展开干脆不拖沓、不回弹遮挡选项。
  static final _openCurve = _CriticalSpringCurve(stiffness: 620, periodSec: .24);
  static const _fadeIn = Interval(0.0, 0.35, curve: Curves.easeOut);
  static const _closeCurve = Curves.easeOutCubic;

  @override
  Widget buildModalBarrier() {
    return RouteInputGate(
      route: this,
      child: _SwipeDismissDropdownBarrier(
        dismissible: barrierDismissible,
        semanticsLabel: barrierLabel,
        onDismiss: () {
          if (isActive) navigator?.pop();
        },
      ),
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final mediaQuery = MediaQuery.of(context);
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: capturedThemes.wrap(
        _AppDropdownMenuOverlay<T>(
          items: items,
          selectedValue: selectedValue,
          selectedIndex: selectedIndex,
          triggerRect: triggerRect,
          matchTriggerWidth: matchTriggerWidth,
          menuMaxHeight: menuMaxHeight,
          menuMinWidth: menuMinWidth,
          menuMaxWidth: menuMaxWidth,
          screenPadding: mediaQuery.padding + mediaQuery.viewInsets,
          animation: animation,
          openCurve: _openCurve,
          fadeInCurve: _fadeIn,
          closeCurve: _closeCurve,
          onSelected: (value) => navigator?.pop(_DropdownResult<T>(value)),
          onCancel: () => navigator?.pop(),
        ),
      ),
    );
  }
}

/// 空白处点击或滑动即刻关闭下拉浮层。
class _SwipeDismissDropdownBarrier extends StatelessWidget {
  const _SwipeDismissDropdownBarrier({
    required this.dismissible,
    required this.semanticsLabel,
    required this.onDismiss,
  });

  final bool dismissible;
  final String semanticsLabel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (!dismissible) {
      return const ModalBarrier(dismissible: false, color: Colors.transparent);
    }
    Offset? downPos;
    var dismissed = false;
    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      onDismiss();
    }

    return Semantics(
      label: semanticsLabel,
      onTap: dismiss,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => downPos = e.position,
        onPointerMove: (e) {
          if (downPos != null && (e.position - downPos!).distance > 8) {
            dismiss();
          }
        },
        onPointerUp: (_) => dismiss(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _AppDropdownMenuOverlay<T> extends StatefulWidget {
  const _AppDropdownMenuOverlay({
    required this.items,
    required this.selectedValue,
    required this.selectedIndex,
    required this.triggerRect,
    required this.matchTriggerWidth,
    required this.menuMaxHeight,
    required this.menuMinWidth,
    required this.menuMaxWidth,
    required this.screenPadding,
    required this.animation,
    required this.openCurve,
    required this.fadeInCurve,
    required this.closeCurve,
    required this.onSelected,
    required this.onCancel,
  });

  final List<AppDropdownItem<T>> items;
  final T? selectedValue;
  final int selectedIndex;
  final Rect triggerRect;
  final bool matchTriggerWidth;
  final double menuMaxHeight;
  final double? menuMinWidth;
  final double? menuMaxWidth;
  final EdgeInsets screenPadding;
  final Animation<double> animation;
  final Curve openCurve;
  final Curve fadeInCurve;
  final Curve closeCurve;
  final ValueChanged<T?> onSelected;
  final VoidCallback onCancel;

  @override
  State<_AppDropdownMenuOverlay<T>> createState() =>
      _AppDropdownMenuOverlayState<T>();
}

class _AppDropdownMenuOverlayState<T>
    extends State<_AppDropdownMenuOverlay<T>> {
  static const double _itemExtentEstimate = 44.0;
  static const double _menuGap = 6.0;
  static const double _screenMargin = 12.0;

  late final ScrollController _scrollController;
  final FocusNode _menuFocusNode = FocusNode();
  int _highlightedIndex = -1;

  @override
  void initState() {
    super.initState();
    _highlightedIndex = widget.selectedIndex >= 0
        ? widget.selectedIndex
        : _nextEnabledIndex(-1, 1);
    final initialOffset = widget.selectedIndex > 2
        ? math.max(0.0, (widget.selectedIndex - 2) * _itemExtentEstimate)
        : 0.0;
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _menuFocusNode.dispose();
    super.dispose();
  }

  int _nextEnabledIndex(int from, int delta) {
    final len = widget.items.length;
    if (len == 0) return -1;
    var index = from;
    for (var i = 0; i < len; i++) {
      index = (index + delta + len) % len;
      if (widget.items[index].enabled) return index;
    }
    return -1;
  }

  void _moveHighlight(int delta) {
    final next = _nextEnabledIndex(_highlightedIndex, delta);
    if (next == -1 || next == _highlightedIndex) return;
    setState(() => _highlightedIndex = next);
    if (_scrollController.hasClients) {
      final target = next * _itemExtentEstimate;
      final min = _scrollController.offset;
      final viewport = _scrollController.position.viewportDimension;
      if (target < min) {
        _scrollController.jumpTo(target);
      } else if (target + _itemExtentEstimate > min + viewport) {
        _scrollController.jumpTo(
          (target + _itemExtentEstimate - viewport).clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
        );
      }
    }
  }

  void _activateHighlighted() {
    if (_highlightedIndex >= 0 && _highlightedIndex < widget.items.length) {
      final item = widget.items[_highlightedIndex];
      if (item.enabled) widget.onSelected(item.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final popupTheme = theme.popupMenuTheme;
    final shapes = context.shapes;
    final emphasis = context.emphasis;
    final isInkControl = emphasis.selected == cs.onSurface;
    final noShadows = popupTheme.elevation == 0;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);

    final Color surfaceColor = popupTheme.color ?? cs.surfaceContainerLow;
    final BorderSide surfaceSide = noShadows
        ? BorderSide(color: cs.outlineVariant)
        : BorderSide(color: cs.outlineVariant.withValues(alpha: 0.32));
    final ShapeBorder surfaceShape = RoundedSuperellipseBorder(
      borderRadius: shapes.borderRadius(16),
      side: surfaceSide,
    );
    final BorderRadius itemRadius = shapes.borderRadius(10);

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenSize = constraints.biggest;
        final safeTop = widget.screenPadding.top + _screenMargin;
        final safeBottom =
            screenSize.height - widget.screenPadding.bottom - _screenMargin;
        final safeLeft = widget.screenPadding.left + _screenMargin;
        final safeRight =
            screenSize.width - widget.screenPadding.right - _screenMargin;
        final availWidth = math.max(120.0, safeRight - safeLeft);

        final spaceBelow = math.max(
          0.0,
          safeBottom - widget.triggerRect.bottom - _menuGap,
        );
        final spaceAbove = math.max(
          0.0,
          widget.triggerRect.top - safeTop - _menuGap,
        );
        final estimatedContentHeight =
            widget.items.length * _itemExtentEstimate + 12;
        final desiredHeight = math.min(
          widget.menuMaxHeight,
          estimatedContentHeight,
        );
        final openUpward =
            spaceBelow < math.min(desiredHeight, 180.0) &&
            spaceAbove > spaceBelow;
        final maxHeight = math.max(
          80.0,
          math.min(widget.menuMaxHeight, openUpward ? spaceAbove : spaceBelow),
        );

        final double minW = widget.menuMinWidth ??
            (widget.matchTriggerWidth
                ? math.min(widget.triggerRect.width, availWidth)
                : math.min(math.max(widget.triggerRect.width, 168.0), availWidth));
        final double maxW = widget.menuMaxWidth ??
            (widget.matchTriggerWidth
                ? math.min(
                    math.max(widget.triggerRect.width, minW),
                    availWidth,
                  )
                : math.min(320.0, availWidth));
        final double clampedMinW = math.min(minW, maxW);

        final Widget menuList = Focus(
          focusNode: _menuFocusNode,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _moveHighlight(1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              _moveHighlight(-1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space) {
              _activateHighlighted();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onCancel();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: clampedMinW,
              maxWidth: maxW,
              maxHeight: maxHeight,
            ),
            child: Material(
              color: surfaceColor,
              surfaceTintColor: Colors.transparent,
              elevation: noShadows ? 0 : 6,
              shadowColor: cs.shadow.withValues(alpha: 0.22),
              shape: surfaceShape,
              clipBehavior: Clip.antiAlias,
              child: IntrinsicWidth(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.items.length; i++) ...[
                        if (i > 0) const SizedBox(height: 2),
                        _AppDropdownOptionTile<T>(
                          item: widget.items[i],
                          selected: widget.items[i].value == widget.selectedValue,
                          highlighted: i == _highlightedIndex,
                          isInkControl: isInkControl,
                          itemRadius: itemRadius,
                          onTap: widget.items[i].enabled
                              ? () => widget.onSelected(widget.items[i].value)
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        final Alignment scaleOrigin = openUpward
            ? Alignment.bottomCenter
            : Alignment.topCenter;

        final Widget animatedMenu = reduceMotion
            ? menuList
            : AnimatedBuilder(
                animation: widget.animation,
                builder: (context, child) {
                  final raw = widget.animation.value;
                  final closing =
                      widget.animation.status == AnimationStatus.reverse;
                  final motion = closing
                      ? widget.closeCurve.transform(raw)
                      : widget.openCurve.transform(raw);
                  final opacity = closing
                      ? widget.closeCurve.transform(raw)
                      : widget.fadeInCurve.transform(raw);
                  final scaleY = 0.90 + 0.10 * motion;
                  final scaleX = 0.96 + 0.04 * motion;
                  return Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: Transform(
                      alignment: scaleOrigin,
                      transform: Matrix4.diagonal3Values(scaleX, scaleY, 1.0),
                      child: child,
                    ),
                  );
                },
                child: menuList,
              );

        return CustomSingleChildLayout(
          delegate: _DropdownPositionDelegate(
            triggerRect: widget.triggerRect,
            openUpward: openUpward,
            gap: _menuGap,
            safeLeft: safeLeft,
            safeRight: safeRight,
            safeTop: safeTop,
            safeBottom: safeBottom,
            textDirection: Directionality.of(context),
          ),
          child: animatedMenu,
        );
      },
    );
  }
}

class _AppDropdownOptionTile<T> extends StatelessWidget {
  const _AppDropdownOptionTile({
    required this.item,
    required this.selected,
    required this.highlighted,
    required this.isInkControl,
    required this.itemRadius,
    required this.onTap,
  });

  final AppDropdownItem<T> item;
  final bool selected;
  final bool highlighted;
  final bool isInkControl;
  final BorderRadius itemRadius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final emphasis = context.emphasis;
    final enabled = item.enabled;

    final Color? bgColor = selected
        ? (isInkControl
              ? cs.onSurface.withValues(alpha: 0.08)
              : cs.secondaryContainer.withValues(alpha: 0.72))
        : highlighted
        ? cs.onSurface.withValues(alpha: 0.05)
        : null;

    final Color textColor = !enabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : selected
        ? (isInkControl ? cs.onSurface : cs.onSecondaryContainer)
        : cs.onSurface;

    final TextStyle labelStyle = (theme.textTheme.bodyMedium ??
            const TextStyle(fontSize: 14))
        .copyWith(
          color: textColor,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );

    final shape = RoundedSuperellipseBorder(borderRadius: itemRadius);

    return Material(
      color: bgColor ?? Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.leading != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(
                      size: 18,
                      color: !enabled
                          ? cs.onSurface.withValues(alpha: 0.38)
                          : selected
                          ? emphasis.selected
                          : cs.onSurfaceVariant,
                    ),
                    child: item.leading!,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.child != null)
                        DefaultTextStyle.merge(
                          style: labelStyle,
                          child: item.child!,
                        )
                      else
                        Text(
                          item.label,
                          style: labelStyle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (item.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: !enabled
                                ? cs.onSurface.withValues(alpha: 0.32)
                                : cs.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 18,
                  child: selected
                      ? Icon(
                          Symbols.check_rounded,
                          size: 18,
                          color: emphasis.selected,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DropdownPositionDelegate extends SingleChildLayoutDelegate {
  const _DropdownPositionDelegate({
    required this.triggerRect,
    required this.openUpward,
    required this.gap,
    required this.safeLeft,
    required this.safeRight,
    required this.safeTop,
    required this.safeBottom,
    required this.textDirection,
  });

  final Rect triggerRect;
  final bool openUpward;
  final double gap;
  final double safeLeft;
  final double safeRight;
  final double safeTop;
  final double safeBottom;
  final TextDirection textDirection;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double preferredX = textDirection == TextDirection.rtl
        ? triggerRect.right - childSize.width
        : triggerRect.left;
    final double maxX = math.max(safeLeft, safeRight - childSize.width);
    final double x = preferredX.clamp(safeLeft, maxX);

    final double preferredY = openUpward
        ? triggerRect.top - gap - childSize.height
        : triggerRect.bottom + gap;
    final double maxY = math.max(safeTop, safeBottom - childSize.height);
    final double y = preferredY.clamp(safeTop, maxY);
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_DropdownPositionDelegate oldDelegate) =>
      triggerRect != oldDelegate.triggerRect ||
      openUpward != oldDelegate.openUpward ||
      safeLeft != oldDelegate.safeLeft ||
      safeRight != oldDelegate.safeRight ||
      safeTop != oldDelegate.safeTop ||
      safeBottom != oldDelegate.safeBottom;
}

/// 临界阻尼弹簧解析解曲线（用于菜单展开，收敛快、无回弹）。
class _CriticalSpringCurve extends Curve {
  _CriticalSpringCurve({required double stiffness, required double periodSec})
    : _sim = SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: stiffness,
          ratio: 1,
        ),
        0,
        1,
        0,
      ),
      _periodSec = periodSec;

  final SpringSimulation _sim;
  final double _periodSec;

  @override
  double transformInternal(double t) => _sim.x(t * _periodSec).clamp(0.0, 1.0);
}
