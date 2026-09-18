import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 正圆提交按钮。进入提交状态后起飞，不等待动效才发请求。
class ComposerSubmitButton extends StatefulWidget {
  const ComposerSubmitButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.busy,
    this.icon,
    this.animateFlight = true,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  /// 紧凑输入条使用 36px，顶栏保持原有 48px 触控外框。
  final bool compact;

  /// 上传准备等等待状态不播放提交起飞。
  final bool animateFlight;

  /// 保存编辑等动作可提供自己的图标；默认纸飞机才播放起飞。
  final IconData? icon;

  @override
  State<ComposerSubmitButton> createState() => _ComposerSubmitButtonState();
}

class _ComposerSubmitButtonState extends State<ComposerSubmitButton>
    with SingleTickerProviderStateMixin {
  late final _flight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: widget.busy ? 1 : 0,
  );
  bool _animate = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate =
        !MediaQuery.disableAnimationsOf(context) &&
        M3eFlags.of(context).enabled;
    if (!_animate) _flight.value = widget.busy ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant ComposerSubmitButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.busy) {
      _flight.value = 0;
    } else if (!oldWidget.busy) {
      if (_animate && widget.animateFlight && widget.icon == null) {
        _flight.forward(from: 0);
      } else {
        _flight.value = 1;
      }
    } else if (oldWidget.icon != widget.icon) {
      _flight.value = 1;
    }
  }

  @override
  void dispose() {
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = widget.compact ? 36.0 : 40.0;
    return Tooltip(
      message: widget.label,
      excludeFromSemantics: true,
      child: SizedBox.square(
        dimension: widget.compact ? 36 : 48,
        child: Center(
          child: FilledButton(
            key: const ValueKey('composer-header-submit'),
            onPressed: widget.busy ? null : widget.onPressed,
            style: FilledButton.styleFrom(
              minimumSize: Size.square(size),
              maximumSize: Size.square(size),
              fixedSize: Size.square(size),
              visualDensity: VisualDensity.standard,
              tapTargetSize: widget.compact
                  ? MaterialTapTargetSize.shrinkWrap
                  : MaterialTapTargetSize.padded,
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
              disabledBackgroundColor: widget.busy ? colors.primary : null,
              disabledForegroundColor: widget.busy ? colors.onPrimary : null,
            ),
            child: Semantics(
              label: widget.label,
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _flight,
                  builder: (context, _) {
                    final progress = widget.busy ? _flight.value : 0.0;
                    return SizedBox.square(
                      dimension: size,
                      child: ClipOval(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (!widget.busy || progress < 1)
                              Opacity(
                                opacity:
                                    1 -
                                    const Interval(
                                      .35,
                                      .95,
                                      curve: Curves.easeIn,
                                    ).transform(progress),
                                child: Transform.translate(
                                  key: const ValueKey('composer-submit-flight'),
                                  offset:
                                      Offset(26, -26) *
                                      Curves.easeInQuad.transform(progress),
                                  child: AppIcon(
                                    widget.icon ?? AppIcons.paperPlane,
                                    size: 21,
                                  ),
                                ),
                              ),
                            if (widget.busy)
                              Opacity(
                                opacity: const Interval(
                                  .65,
                                  1,
                                ).transform(progress),
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    color: colors.onPrimary,
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
