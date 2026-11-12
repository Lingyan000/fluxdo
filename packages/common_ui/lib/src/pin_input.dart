import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui_shapes.dart';

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

  @override
  State<PinInput> createState() => _PinInputState();
}

class _PinInputState extends State<PinInput> {
  final _ownedFocus = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _ownedFocus;

  @override
  void dispose() {
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 10),
        ListenableBuilder(
          listenable: Listenable.merge([widget.controller, _focus]),
          builder: (context, _) => SizedBox(
            height: 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ExcludeSemantics(
                  child: Row(
                    spacing: 8,
                    children: List.generate(widget.length, (index) {
                      final filled = index < widget.controller.text.length;
                      final selected =
                          widget.enabled &&
                          _focus.hasFocus &&
                          index == widget.controller.text.length;
                      return Expanded(
                        child: AnimatedContainer(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 150),
                          decoration: ShapeDecoration(
                            color: colors.surfaceContainerLow,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: context.shapes.borderRadius(12),
                              side: BorderSide(
                                color: selected
                                    ? colors.primary
                                    : colors.outlineVariant,
                                width: selected ? 2 : 1,
                              ),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              filled ? '•' : '',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: colors.onSurface,
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                Semantics(
                  label: widget.label,
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    enabled: widget.enabled,
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
              ],
            ),
          ),
        ),
      ],
    );
  }
}
