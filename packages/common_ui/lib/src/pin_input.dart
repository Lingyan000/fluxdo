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
    if (widget.statusLabel != null) {
      _join.value = 1;
      _status.value = 1;
    }
  }

  @override
  void didUpdateWidget(PinInput oldWidget) {
    super.didUpdateWidget(oldWidget);
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
      return;
    }
    _join.animateWith(
      SpringSimulation(_joinSlots, _join.value, target, _join.velocity),
    );
    if (target == 0) {
      _status.value = 0;
    } else {
      // 合拢后再显露状态；请求由调用方立即执行，不等待动画。
      _statusDelay = Timer(const Duration(milliseconds: 300), () {
        _status.animateWith(
          SpringSimulation(_statusFade, _status.value, 1, _status.velocity),
        );
      });
    }
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
            ListenableBuilder(
              listenable: Listenable.merge([
                widget.controller,
                _focus,
                _join,
                _status,
              ]),
              builder: (context, _) => SizedBox(
                height: math.max(
                  56,
                  MediaQuery.textScalerOf(context).scale(40),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final join = _join.value.clamp(0.0, 1.0);
                    final gap = 8 * (1 - join);
                    final slotWidth =
                        (constraints.maxWidth - 8 * (widget.length - 1)) /
                        widget.length;
                    final totalWidth =
                        slotWidth * widget.length + gap * (widget.length - 1);
                    final start = (constraints.maxWidth - totalWidth) / 2;
                    final radius = context.shapes.borderRadius(14);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(
                          child: Stack(
                            children: List.generate(widget.length, (index) {
                              final selected =
                                  widget.enabled &&
                                  !busy &&
                                  _focus.hasFocus &&
                                  index == widget.controller.text.length;
                              return Positioned(
                                key: ValueKey(index),
                                left: start + index * (slotWidth + gap),
                                top: 0,
                                bottom: 0,
                                width:
                                    slotWidth +
                                    (index < widget.length - 1 ? 9 * join : 0),
                                child: _PinSlot(
                                  character:
                                      index < widget.controller.text.length
                                      ? widget.controller.text[index]
                                      : '',
                                  selected: selected,
                                  join: join,
                                  reduceMotion: _reduceMotion,
                                  radius: radius.copyWith(
                                    topLeft: index == 0
                                        ? radius.topLeft
                                        : Radius.lerp(
                                            radius.topLeft,
                                            Radius.zero,
                                            join,
                                          ),
                                    bottomLeft: index == 0
                                        ? radius.bottomLeft
                                        : Radius.lerp(
                                            radius.bottomLeft,
                                            Radius.zero,
                                            join,
                                          ),
                                    topRight: index == widget.length - 1
                                        ? radius.topRight
                                        : Radius.lerp(
                                            radius.topRight,
                                            Radius.zero,
                                            join,
                                          ),
                                    bottomRight: index == widget.length - 1
                                        ? radius.bottomRight
                                        : Radius.lerp(
                                            radius.bottomRight,
                                            Radius.zero,
                                            join,
                                          ),
                                  ),
                                ),
                              );
                            }),
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
                        if (busy)
                          Positioned(
                            left: start,
                            right: start,
                            top: 0,
                            bottom: 0,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Semantics(
                                liveRegion: true,
                                label: widget.statusLabel,
                                excludeSemantics: true,
                                child: Opacity(
                                  opacity: (_status.value * 1.6 - .5).clamp(
                                    0.0,
                                    1.0,
                                  ),
                                  child: Transform.translate(
                                    offset: Offset(
                                      0,
                                      8 * (1 - _status.value.clamp(0.0, 1.0)),
                                    ),
                                    child: Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        spacing: 8,
                                        children: [
                                          if (widget.statusIcon != null)
                                            widget.statusIcon!,
                                          Flexible(
                                            child: Text(
                                              widget.statusLabel!,
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
                      ],
                    );
                  },
                ),
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
    required this.character,
    required this.selected,
    required this.join,
    required this.radius,
    required this.reduceMotion,
  });

  final String character;
  final bool selected, reduceMotion;
  final double join;
  final BorderRadius radius;

  @override
  State<_PinSlot> createState() => _PinSlotState();
}

class _PinSlotState extends State<_PinSlot> with TickerProviderStateMixin {
  late final _drop = AnimationController.unbounded(vsync: this);
  late final _fade = AnimationController.unbounded(
    vsync: this,
    value: widget.character.isEmpty ? 0 : 1,
  );
  late final _active = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );

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
    if (widget.reduceMotion) {
      _drop.value = 0;
      _fade.value = widget.character.isEmpty ? 0 : 1;
      _active.value = widget.selected ? 1 : 0;
      return;
    }
    if (oldWidget.character != widget.character) {
      if (widget.character.isNotEmpty) {
        _drop.value = -14;
        _fade.value = 0;
        _animate(_drop, _digitDrop, 0);
      }
      _animate(_fade, _digitFade, widget.character.isEmpty ? 0 : 1);
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
      listenable: Listenable.merge([_drop, _fade, _active]),
      builder: (context, _) {
        final active = _active.value.clamp(0.0, 1.0) * (1 - widget.join);
        final fill = Color.alphaBlend(
          accent.withValues(alpha: active * .12),
          colors.surfaceContainerLow,
        );
        return DecoratedBox(
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedSuperellipseBorder(
              borderRadius: widget.radius,
              side: BorderSide(
                color: Color.lerp(
                  colors.outlineVariant,
                  accent,
                  active,
                )!.withValues(alpha: 1 - widget.join),
                width: 1 + active,
              ),
            ),
          ),
          child: Center(
            child: Opacity(
              opacity: _fade.value.clamp(0.0, 1.0) * (1 - widget.join),
              child: Transform.translate(
                offset: Offset(0, _drop.value),
                child: Text(
                  widget.character.isEmpty ? '' : '•',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colors.onSurface,
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
