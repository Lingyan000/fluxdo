import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'ui_emphasis.dart';
import 'ui_shapes.dart';

const _digitDrop = SpringDescription(mass: 1, stiffness: 520, damping: 16);
const _digitFade = SpringDescription(mass: 1, stiffness: 400, damping: 28);
const _focusFill = SpringDescription(mass: 1, stiffness: 300, damping: 26);
const _joinSlots = SpringDescription(mass: 1, stiffness: 260, damping: 24);
const _statusFade = SpringDescription(mass: 1, stiffness: 220, damping: 28);

/// 单个安全输入框配合分格显示，保留键盘、粘贴与读屏的标准输入行为。
class PinInput extends StatefulWidget {
  const PinInput({
    super.key,
    required this.controller,
    required this.label,
    this.length = 6,
    this.enabled = true,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction = TextInputAction.done,
    this.keyboardType = TextInputType.number,
    this.focusNode,
    this.statusLabel,
    this.statusIcon,
  }) : assert(length > 0);

  final TextEditingController controller;
  final String label;
  final int length;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction textInputAction;
  final TextInputType keyboardType;
  final FocusNode? focusNode;

  /// 调用方进入处理状态时合拢格子。输入完成本身不触发状态变化。
  final String? statusLabel;
  final Widget? statusIcon;

  @override
  State<PinInput> createState() => _PinInputState();
}

class _PinInputState extends State<PinInput> with TickerProviderStateMixin {
  final _ownedFocus = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _ownedFocus;
  late final _join = AnimationController.unbounded(vsync: this);
  late final _status = AnimationController.unbounded(vsync: this);
  Timer? _statusDelay;
  bool _reduceMotion = false;
  String? _statusLabel;
  Widget? _statusIcon;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _updateStatus();
    }
  }

  @override
  void initState() {
    super.initState();
    _statusLabel = widget.statusLabel;
    _statusIcon = widget.statusIcon;
    if (widget.statusLabel != null) {
      _join.value = 1;
      _status.value = 1;
    }
  }

  @override
  void didUpdateWidget(PinInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.statusLabel != null) {
      _statusLabel = widget.statusLabel;
      _statusIcon = widget.statusIcon;
    }
    if ((oldWidget.statusLabel != null) != (widget.statusLabel != null)) {
      _updateStatus();
    }
  }

  void _updateStatus() {
    _statusDelay?.cancel();
    final target = widget.statusLabel != null ? 1.0 : 0.0;
    if (_reduceMotion) {
      _join.value = target;
      _status.value = target;
      if (target == 0) _clearStatus();
      return;
    }
    _join.animateWith(
      SpringSimulation(_joinSlots, _join.value, target, _join.velocity),
    );
    if (target == 0) {
      _status
          .animateWith(
            SpringSimulation(_statusFade, _status.value, 0, _status.velocity),
          )
          .whenCompleteOrCancel(() {
            if (mounted && widget.statusLabel == null && !_status.isAnimating) {
              setState(_clearStatus);
            }
          });
    } else if (_status.value > 0) {
      _showStatus();
    } else {
      // 合拢后再显露状态；请求由调用方立即执行，不等待动画。
      _statusDelay = Timer(const Duration(milliseconds: 300), _showStatus);
    }
  }

  void _showStatus() => _status.animateWith(
    SpringSimulation(_statusFade, _status.value, 1, _status.velocity),
  );

  void _clearStatus() {
    _statusLabel = null;
    _statusIcon = null;
  }

  @override
  void dispose() {
    _statusDelay?.cancel();
    _join.dispose();
    _status.dispose();
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = widget.statusLabel != null;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.length * 48.0 + (widget.length - 1) * 8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
            SizedBox(
              height: math.max(56, MediaQuery.textScalerOf(context).scale(40)),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final slotWidth =
                      (constraints.maxWidth - 8 * (widget.length - 1)) /
                      widget.length;
                  final radius = context.shapes.borderRadius(14);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ExcludeSemantics(
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            widget.controller,
                            _focus,
                          ]),
                          builder: (context, _) => Stack(
                            children: List.generate(widget.length, (index) {
                              final selected =
                                  widget.enabled &&
                                  !busy &&
                                  _focus.hasFocus &&
                                  index == widget.controller.text.length;
                              return AnimatedBuilder(
                                key: ValueKey(index),
                                animation: _join,
                                builder: (context, child) {
                                  final join = _join.value.clamp(0.0, 1.0);
                                  final gap = 8 * (1 - join);
                                  final start = 4 * (widget.length - 1) * join;
                                  return Positioned(
                                    left: start + index * (slotWidth + gap),
                                    top: 0,
                                    bottom: 0,
                                    width:
                                        slotWidth +
                                        (index < widget.length - 1
                                            ? 9 * join
                                            : 0),
                                    child: child!,
                                  );
                                },
                                child: _PinSlot(
                                  filled: index < widget.controller.text.length,
                                  processing: busy,
                                  selected: selected,
                                  join: _join,
                                  status: _status,
                                  reduceMotion: _reduceMotion,
                                  radius: radius,
                                  first: index == 0,
                                  last: index == widget.length - 1,
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                      ExcludeSemantics(
                        excluding: busy,
                        child: Semantics(
                          label: widget.label,
                          child: TextField(
                            controller: widget.controller,
                            focusNode: _focus,
                            enabled: widget.enabled && !busy,
                            obscureText: true,
                            obscuringCharacter: '•',
                            showCursor: false,
                            enableSuggestions: false,
                            autocorrect: false,
                            keyboardType: widget.keyboardType,
                            textInputAction: widget.textInputAction,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(widget.length),
                            ],
                            style: const TextStyle(color: Colors.transparent),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onChanged: widget.onChanged,
                            onSubmitted: widget.onSubmitted,
                          ),
                        ),
                      ),
                      if (_statusLabel != null)
                        Positioned(
                          left: 4 * (widget.length - 1),
                          right: 4 * (widget.length - 1),
                          top: 0,
                          bottom: 0,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: IgnorePointer(
                              child: ExcludeSemantics(
                                excluding: !busy,
                                child: Semantics(
                                  liveRegion: true,
                                  label: _statusLabel,
                                  excludeSemantics: true,
                                  child: AnimatedBuilder(
                                    animation: _status,
                                    builder: (context, child) => Opacity(
                                      opacity: (_status.value * 1.6 - .5).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                      child: Transform.translate(
                                        offset: Offset(
                                          0,
                                          8 *
                                              (1 -
                                                  _status.value.clamp(
                                                    0.0,
                                                    1.0,
                                                  )),
                                        ),
                                        child: child,
                                      ),
                                    ),
                                    child: Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        spacing: 8,
                                        children: [
                                          ?_statusIcon,
                                          Flexible(
                                            child: Text(
                                              _statusLabel!,
                                              textAlign: TextAlign.center,
                                              style: theme.textTheme.labelLarge,
                                            ),
                                          ),
                                        ],
                                      ),
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
            ),
          ],
        ),
      ),
    );
  }
}

class _PinSlot extends StatefulWidget {
  const _PinSlot({
    required this.filled,
    required this.processing,
    required this.selected,
    required this.join,
    required this.status,
    required this.radius,
    required this.reduceMotion,
    required this.first,
    required this.last,
  });

  final bool filled, processing, selected, reduceMotion, first, last;
  final Animation<double> join, status;
  final BorderRadius radius;

  @override
  State<_PinSlot> createState() => _PinSlotState();
}

class _PinSlotState extends State<_PinSlot> with TickerProviderStateMixin {
  // 控制器清空后仅保留遮罩的可见状态，绝不缓存密码字符。
  late bool _filled;
  late final _drop = AnimationController.unbounded(vsync: this);
  late final _fade = AnimationController.unbounded(
    vsync: this,
    value: widget.filled ? 1 : 0,
  );
  late final _active = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    _filled = widget.filled;
  }

  void _animate(
    AnimationController controller,
    SpringDescription spring,
    double target,
  ) {
    controller.animateWith(
      SpringSimulation(spring, controller.value, target, controller.velocity),
    );
  }

  @override
  void didUpdateWidget(_PinSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final filled = widget.filled || (widget.processing && _filled);
    if (widget.reduceMotion) {
      _filled = filled;
      _drop.value = 0;
      _fade.value = filled ? 1 : 0;
      _active.value = widget.selected ? 1 : 0;
      return;
    }
    if (oldWidget.processing && !widget.processing) {
      // 状态退场不重新露出已清空的旧遮罩。
      _fade.value =
          _fade.value.clamp(0.0, 1.0) *
          (1 - widget.status.value.clamp(0.0, 1.0));
    }
    if (_filled != filled || (oldWidget.processing && !widget.processing)) {
      // 快速删除后再次输入时沿用当前位移、速度与透明度。
      if (filled && !_filled && _fade.value <= .001) {
        _drop.value = -14;
        _fade.value = 0;
        _animate(_drop, _digitDrop, 0);
      }
      _filled = filled;
      _animate(_fade, _digitFade, filled ? 1 : 0);
    }
    if (oldWidget.selected != widget.selected) {
      _animate(_active, _focusFill, widget.selected ? 1 : 0);
    }
  }

  @override
  void dispose() {
    _drop.dispose();
    _fade.dispose();
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = context.emphasis.selected;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _drop,
        _fade,
        _active,
        widget.join,
        widget.status,
      ]),
      child: Text(
        '•',
        style: theme.textTheme.headlineSmall?.copyWith(color: colors.onSurface),
      ),
      builder: (context, child) {
        final join = widget.join.value.clamp(0.0, 1.0);
        final status = widget.processing
            ? widget.status.value.clamp(0.0, 1.0)
            : 0.0;
        final active = _active.value.clamp(0.0, 1.0) * (1 - join);
        final radius = widget.radius;
        final fill = Color.alphaBlend(
          accent.withValues(alpha: active * .12),
          colors.surfaceContainerLow,
        );
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedSuperellipseBorder(
              borderRadius: radius.copyWith(
                topLeft: widget.first
                    ? radius.topLeft
                    : Radius.lerp(radius.topLeft, Radius.zero, join),
                bottomLeft: widget.first
                    ? radius.bottomLeft
                    : Radius.lerp(radius.bottomLeft, Radius.zero, join),
                topRight: widget.last
                    ? radius.topRight
                    : Radius.lerp(radius.topRight, Radius.zero, join),
                bottomRight: widget.last
                    ? radius.bottomRight
                    : Radius.lerp(radius.bottomRight, Radius.zero, join),
              ),
              side: BorderSide(
                color: Color.lerp(
                  colors.outlineVariant,
                  accent,
                  active,
                )!.withValues(alpha: 1 - join),
                width: 1 + active,
              ),
            ),
          ),
          child: Center(
            child: Opacity(
              opacity: _fade.value.clamp(0.0, 1.0) * (1 - status),
              child: Transform.translate(
                offset: Offset(0, _drop.value),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
