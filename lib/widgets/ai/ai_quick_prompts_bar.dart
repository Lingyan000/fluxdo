import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import 'ai_quick_prompts_sheet.dart';

/// AI 助手底部的快捷词 chip 行
///
/// 显示当前 [type] 下所有 pinned 的 preset，点击一个 chip 就直接用对应 preset
/// 触发 [onPick]（送给上层 _sendQuickPrompt 之类的回调）。
///
/// 末尾跟一个「更多」chip → 弹 [AiQuickPromptsSheet] 显示全部 preset。
class AiQuickPromptsBar extends ConsumerWidget {
  const AiQuickPromptsBar({
    super.key,
    required this.type,
    required this.topicTitle,
    required this.onPick,
    this.stacked = false,
  });

  /// true = 垂直堆叠（每个 pill 一行，左对齐），适合空状态 Kimi 风格
  /// false = Wrap chip（默认，适合输入框上方紧凑展示）
  final bool stacked;

  final PromptType type;

  /// 话题标题，用于把 preset.promptTemplate 中的 `{title}` 替换为实际值
  final String topicTitle;

  /// 用户选了一个 preset 时的回调
  final void Function(
    PromptPreset preset,
    Map<String, String>? dimensionValues,
    String renderedPrompt,
    String? aspectRatio,
  ) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(pinnedPromptPresetsProvider(type));
    final chips = <Widget>[
      for (final p in pinned)
        ActionChip(
          avatar: PresetIcon(iconRaw: p.iconRaw, size: 16),
          label: Text(p.name),
          onPressed: () => _handlePick(context, p),
        ),
      ActionChip(
        avatar: const Icon(Symbols.more_horiz_rounded, size: 16),
        label: Text(S.current.ai_quickPromptsMore),
        onPressed: () => _openSheet(context),
      ),
    ];

    if (stacked) {
      // Kimi 式：每个 pill 一行，左对齐，intrinsic 宽度
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            chips[i],
          ],
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: chips,
    );
  }

  void _handlePick(BuildContext context, PromptPreset preset) {
    if (!preset.hasDimensions) {
      final rendered = renderPromptTemplate(
        preset.promptTemplate,
        title: _safeTitle(),
      );
      onPick(preset, null, rendered, preset.aspectRatio);
      return;
    }
    // 有维度 → 弹维度选择 sheet
    showAiPresetDimensionSheet(
      context: context,
      preset: preset,
      onConfirm: (dimensionValues) {
        final base = renderPromptTemplate(
          preset.promptTemplate,
          title: _safeTitle(),
        );
        final rendered = appendDimensionFragments(
          base,
          preset.dimensions,
          dimensionValues,
        );
        // aspect 维度的值优先于 preset.aspectRatio
        final aspectValue = dimensionValues['aspect'] ?? preset.aspectRatio;
        onPick(preset, dimensionValues, rendered, aspectValue);
      },
    );
  }

  void _openSheet(BuildContext context) {
    showAiQuickPromptsSheet(
      context: context,
      type: type,
      onPick: (preset, dimensionValues) {
        final base = renderPromptTemplate(
          preset.promptTemplate,
          title: _safeTitle(),
        );
        final rendered = preset.hasDimensions
            ? appendDimensionFragments(base, preset.dimensions, dimensionValues)
            : base;
        final aspectValue =
            dimensionValues?['aspect'] ?? preset.aspectRatio;
        onPick(preset, dimensionValues, rendered, aspectValue);
      },
    );
  }

  String _safeTitle() {
    final trimmed = topicTitle.trim();
    return trimmed.isEmpty ? S.current.ai_title : trimmed;
  }
}
