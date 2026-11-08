import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'm3e_flags.dart';
import 'm3e_motion.dart';

/// 原 M3 开关的占位与轨道尺寸；按压/拖动仅改变滑块的绘制形状。
/// 拖动在松手时提交一次，取消或宿主拒绝新值时回到受控值。
class M3eSwitch extends StatefulWidget {
  const M3eSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.semanticLabel,
    this.materialTapTargetSize,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final MaterialTapTargetSize? materialTapTargetSize;

  @override
  State<M3eSwitch> createState() => _M3eSwitchState();
}

class _M3eSwitchState extends State<M3eSwitch> with TickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 320);
  static final _spring = M3eMotion.fastSpatial.curveFor(_duration);
  late final _position = AnimationController(
    vsync: this,
    value: widget.value ? 1 : 0,
  );
  late final _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );
  late final _motion = Listenable.merge([_position, _press]);
  bool _dragging = false;
  bool _focused = false;
  bool _reduced = false;
  bool get _enabled => widget.onChanged != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced || !M3eFlags.of(context).enabled) {
      _position.value = widget.value ? 1 : 0;
      _press.value = 0;
    }
  }

  @override
  void didUpdateWidget(M3eSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled) {
      _dragging = false;
      _press.value = 0;
    }
    if (!_dragging && (oldWidget.value != widget.value || !_enabled)) _settle();
  }

  void _settle() {
    final target = widget.value ? 1.0 : 0.0;
    if (_reduced) {
      _position.value = target;
    } else {
      _position.animateTo(target, duration: _duration, curve: _spring);
    }
  }

  void _pressTo(double target) {
    if (_reduced) return;
    _press.animateTo(target, curve: Curves.easeOutCubic);
  }

  void _commit(bool value) {
    if (_enabled && value != widget.value) widget.onChanged!(value);
    // 受控组件：宿主可能接受或拒绝，也可能在回调中关闭整个页面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_dragging) _settle();
    });
  }

  void _tap() {
    if (!_enabled || _dragging) return;
    _pressTo(0);
    _commit(!widget.value);
  }

  void _cancel() {
    _dragging = false;
    _pressTo(0);
    _settle();
  }

  @override
  void dispose() {
    _position.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return Switch(
        value: widget.value,
        onChanged: widget.onChanged,
        focusNode: widget.focusNode,
        materialTapTargetSize: widget.materialTapTargetSize,
      );
    }
    final theme = Theme.of(context);
    final switchTheme = SwitchTheme.of(context);
    final target =
        widget.materialTapTargetSize ??
        switchTheme.materialTapTargetSize ??
        theme.materialTapTargetSize;
    final height = target == MaterialTapTargetSize.padded ? 48.0 : 40.0;
    final padding =
        (switchTheme.padding ?? const EdgeInsets.symmetric(horizontal: 4))
            .resolve(Directionality.of(context));
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      label: widget.semanticLabel,
      toggled: widget.value,
      enabled: _enabled,
      onTap: _enabled ? _tap : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        focusNode: widget.focusNode,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _tap();
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              _tap();
              return null;
            },
          ),
        },
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          gestures: _enabled
              ? {
                  TapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        TapGestureRecognizer
                      >(
                        () => TapGestureRecognizer(),
                        (recognizer) => recognizer
                          ..onTapDown = (_) {
                            _pressTo(1);
                          }
                          ..onTap = _tap
                          ..onTapCancel = () {
                            if (!_dragging) _pressTo(0);
                          },
                      ),
                  _SwitchDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        _SwitchDragRecognizer
                      >(
                        () => _SwitchDragRecognizer(),
                        (recognizer) => recognizer
                          ..onStart = (_) {
                            _dragging = true;
                            _position.stop();
                            _pressTo(1);
                          }
                          ..onUpdate = (details) {
                            if (!_dragging || !_enabled) return;
                            _position.value +=
                                (rtl ? -1 : 1) * details.delta.dx / 20;
                          }
                          ..onEnd = (_) {
                            if (!_dragging) return;
                            _dragging = false;
                            _pressTo(0);
                            _commit(_position.value >= .5);
                          }
                          ..onCancel = _cancel,
                      ),
                }
              : const {},
          child: Padding(
            padding: padding,
            child: SizedBox(
              width: 52,
              height: height,
              child: AnimatedBuilder(
                animation: _motion,
                builder: (context, _) =>
                    _parts(theme.colorScheme, switchTheme, rtl, height),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _parts(
    ColorScheme colors,
    SwitchThemeData theme,
    bool rtl,
    double height,
  ) {
    final t = _position.value;
    final lift = _press.value;
    Color? resolve(WidgetStateProperty<Color?>? property, bool selected) =>
        property?.resolve({
          if (!_enabled) WidgetState.disabled,
          if (selected) WidgetState.selected,
        });
    final track = Color.lerp(
      resolve(theme.trackColor, false) ?? colors.surfaceContainerHighest,
      resolve(theme.trackColor, true) ?? colors.primary,
      t,
    )!;
    final thumb = Color.lerp(
      resolve(theme.thumbColor, false) ?? colors.outline,
      resolve(theme.thumbColor, true) ?? colors.onPrimary,
      t,
    )!;
    final stretch = math.sin(math.pi * t);
    final thumbWidth = 24 + stretch * 6 + lift * 8;
    final thumbHeight = 24 - stretch * 2 + lift * 6;
    final centerX = 16 + 20 * (rtl ? 1 - t : t);
    return Opacity(
      opacity: _enabled ? 1 : .38,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: 52,
            height: 32,
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          Positioned(
            left: centerX - thumbWidth / 2,
            top: (height - thumbHeight) / 2,
            child: Container(
              width: thumbWidth,
              height: thumbHeight,
              decoration: BoxDecoration(
                color: thumb,
                borderRadius: BorderRadius.circular(thumbHeight / 2),
                boxShadow: [
                  if (lift > 0)
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: .15 * lift),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                ],
              ),
            ),
          ),
          if (_focused)
            Container(
              width: 52,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: colors.primary, width: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// 第二根手指不能接管正在进行的拖动。
class _SwitchDragRecognizer extends HorizontalDragGestureRecognizer {
  int? _pointer;
  @override
  bool isPointerAllowed(PointerEvent event) =>
      _pointer == null && super.isPointerAllowed(event);
  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerCancelEvent && event.pointer == _pointer) {
      // Flutter 的已获胜 drag 会把 PointerCancel 也交给 onEnd。
      // 先撤销展示和提交状态，避免系统取消被误当作用户松手。
      onCancel?.call();
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    _pointer = null;
  }
}

/// 保留 SwitchListTile 的整行点击、单一语义节点和键盘焦点。
class M3eSwitchListTile extends StatelessWidget {
  const M3eSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.secondary,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return SwitchListTile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        secondary: secondary,
      );
    }
    final control = ExcludeFocus(
      child: M3eSwitch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
    final leading =
        ListTileTheme.of(context).controlAffinity ==
        ListTileControlAffinity.leading;
    return MergeSemantics(
      child: ListTile(
        leading: leading ? control : secondary,
        trailing: leading ? secondary : control,
        title: title,
        subtitle: subtitle,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
      ),
    );
  }
}
