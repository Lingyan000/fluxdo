import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_provider.dart';

/// 模型能力标签行，用 icon pill 展示 IO 模态和能力。
/// 参考 Kelivo `ModelTagWrap` 设计。
class ModelTagWrap extends StatelessWidget {
  const ModelTagWrap({super.key, required this.model});

  final AiModel model;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chips = <Widget>[];

    // IO 模态 pill：输入 icon → 输出 icon
    chips.add(
      _buildIoPill(context, cs, isDark),
    );

    // 能力 pill
    if (model.abilities.contains(ModelAbility.tool)) {
      chips.add(_buildAbilityPill(
        context,
        icon: Symbols.handyman_rounded,
        label: AiL10n.current.modelDetailToolAbility,
        color: cs.primary,
        isDark: isDark,
      ));
    }
    if (model.abilities.contains(ModelAbility.reasoning)) {
      chips.add(_buildAbilityPill(
        context,
        icon: Symbols.psychology_rounded,
        label: AiL10n.current.modelDetailReasoningAbility,
        color: cs.secondary,
        isDark: isDark,
      ));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }

  Widget _buildIoPill(BuildContext context, ColorScheme cs, bool isDark) {
    final color = cs.tertiary;
    final inputMods = model.input.isEmpty ? const [Modality.text] : model.input;
    final outputMods =
        model.output.isEmpty ? const [Modality.text] : model.output;

    final inputLabel = inputMods
        .map((m) => m == Modality.text
            ? AiL10n.current.modelDetailTextMode
            : AiL10n.current.modelDetailImageMode)
        .join(', ');
    final outputLabel = outputMods
        .map((m) => m == Modality.text
            ? AiL10n.current.modelDetailTextMode
            : AiL10n.current.modelDetailImageMode)
        .join(', ');
    final tooltip = '$inputLabel → $outputLabel';

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: ShapeDecoration(
              color: isDark
                  ? color.withValues(alpha: 0.25)
                  : color.withValues(alpha: 0.15),
              shape: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(999),
                side: BorderSide(
                  color: color.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mod in inputMods)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(
                      mod == Modality.text
                          ? Symbols.text_fields_rounded
                          : Symbols.image_rounded,
                      size: 12,
                      color: isDark ? color : color.withValues(alpha: 0.9),
                    ),
                  ),
                Icon(
                  Symbols.chevron_right_rounded,
                  size: 12,
                  color: isDark ? color : color.withValues(alpha: 0.9),
                ),
                for (final mod in outputMods)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Icon(
                      mod == Modality.text
                          ? Symbols.text_fields_rounded
                          : Symbols.image_rounded,
                      size: 12,
                      color: isDark ? color : color.withValues(alpha: 0.9),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAbilityPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: ShapeDecoration(
              color: isDark
                  ? color.withValues(alpha: 0.25)
                  : color.withValues(alpha: 0.15),
              shape: RoundedSuperellipseBorder(
                borderRadius: context.shapes.borderRadius(999),
                side: BorderSide(
                  color: color.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
            ),
            child: Icon(
              icon,
              size: 12,
              color: isDark ? color : color.withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );
  }
}
