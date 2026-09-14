import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 通过填色表达状态，沿用原生圆形反馈，点击区域始终保持 48dp。
ButtonStyle composerToolButtonStyle(
  BuildContext context, {
  bool active = false,
}) {
  final colors = Theme.of(context).colorScheme;
  final motion =
      M3eFlags.of(context).enabled && !MediaQuery.disableAnimationsOf(context);
  return IconButton.styleFrom(
    minimumSize: const Size.square(48),
    maximumSize: const Size.square(48),
    padding: const EdgeInsets.all(12),
    visualDensity: VisualDensity.standard,
    foregroundColor: active
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant,
    backgroundColor: active ? colors.secondaryContainer : Colors.transparent,
  ).copyWith(
    animationDuration: motion
        ? const Duration(milliseconds: 150)
        : Duration.zero,
  );
}

/// 内容处理和光标共享一个轻量底色，模式切换留在组外。
class ComposerEditingControls extends StatelessWidget {
  const ComposerEditingControls({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}
