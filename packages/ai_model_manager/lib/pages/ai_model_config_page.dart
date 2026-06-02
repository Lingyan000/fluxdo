import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_provider.dart';
import '../providers/ai_chat_providers.dart';
import '../providers/ai_provider_providers.dart';
import '../utils/dialog_utils.dart';
import '../widgets/model_icon.dart';

class AiModelConfigPage extends ConsumerWidget {
  const AiModelConfigPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allModels = ref.watch(allAvailableAiModelsProvider);
    final textDefaultKey = ref.watch(defaultTextAiModelKeyProvider);
    final imageDefaultKey = ref.watch(defaultImageAiModelKeyProvider);
    final titleModel = ref.watch(aiTitleModelProvider);
    final optimizer = ref.watch(aiImagePromptOptimizerModelProvider);

    final textDefault = _resolveModel(allModels, textDefaultKey);
    final imageDefault = _resolveModel(allModels, imageDefaultKey);

    return Scaffold(
      appBar: AppBar(title: Text(AiL10n.current.modelConfig)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _ModelCard(
            icon: Icons.chat_outlined,
            title: AiL10n.current.defaultChatModel,
            current: textDefault,
            onPick: () => _showPicker(
              context, ref,
              allModels
                  .where((m) => m.model.output.contains(Modality.text))
                  .toList(),
              currentKey: textDefaultKey,
              onSelect: (p, m) =>
                  setDefaultAiModel(ref, p, m, isImageMode: false),
              onClear: () => clearDefaultAiModel(ref, isImageMode: false),
            ),
            onReset: textDefaultKey != null
                ? () => clearDefaultAiModel(ref, isImageMode: false)
                : null,
          ),
          const SizedBox(height: 12),
          _ModelCard(
            icon: Icons.image_outlined,
            title: AiL10n.current.defaultImageModel,
            current: imageDefault,
            onPick: () => _showPicker(
              context, ref,
              allModels
                  .where((m) => m.model.output.contains(Modality.image))
                  .toList(),
              currentKey: imageDefaultKey,
              onSelect: (p, m) =>
                  setDefaultAiModel(ref, p, m, isImageMode: true),
              onClear: () => clearDefaultAiModel(ref, isImageMode: true),
            ),
            onReset: imageDefaultKey != null
                ? () => clearDefaultAiModel(ref, isImageMode: true)
                : null,
          ),
          const SizedBox(height: 12),
          _ModelCard(
            icon: Icons.title_outlined,
            title: AiL10n.current.titleGenerationModel,
            subtitle: AiL10n.current.autoGenerateTitleSubtitle,
            current: titleModel,
            onPick: () => _showPicker(
              context, ref, allModels,
              current: titleModel,
              clearLabel: AiL10n.current.noAutoGenerateTitle,
              onSelect: (p, m) => setAiTitleModel(ref, p, m),
              onClear: () => setAiTitleModel(ref, null, null),
            ),
            onReset: titleModel != null
                ? () => setAiTitleModel(ref, null, null)
                : null,
          ),
          const SizedBox(height: 12),
          _ModelCard(
            icon: Icons.auto_fix_high_outlined,
            title: AiL10n.current.imagePromptOptimizerModel,
            subtitle: AiL10n.current.imagePromptOptimizerSubtitle,
            current: optimizer,
            onPick: () => _showPicker(
              context, ref,
              allModels
                  .where((m) => m.model.output.contains(Modality.text))
                  .toList(),
              current: optimizer,
              clearLabel: AiL10n.current.optimizerNotSet,
              onSelect: (p, m) =>
                  setAiImagePromptOptimizerModel(ref, p, m),
              onClear: () =>
                  setAiImagePromptOptimizerModel(ref, null, null),
            ),
            onReset: optimizer != null
                ? () => setAiImagePromptOptimizerModel(ref, null, null)
                : null,
          ),
        ],
      ),
    );
  }

  ({AiProvider provider, AiModel model})? _resolveModel(
    List<({AiProvider provider, AiModel model})> allModels,
    String? key,
  ) {
    if (key == null) return null;
    final parts = key.split(':');
    if (parts.length < 2) return null;
    final pid = parts[0];
    final mid = parts.sublist(1).join(':');
    for (final m in allModels) {
      if (m.provider.id == pid && m.model.id == mid) return m;
    }
    return null;
  }

  void _showPicker(
    BuildContext context,
    WidgetRef ref,
    List<({AiProvider provider, AiModel model})> models, {
    String? currentKey,
    ({AiProvider provider, AiModel model})? current,
    String? clearLabel,
    required void Function(String providerId, String modelId) onSelect,
    required VoidCallback onClear,
  }) {
    showAppBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            ListTile(
              title: Text(clearLabel ?? AiL10n.current.notSet),
              trailing: (currentKey == null && current == null)
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                onClear();
                Navigator.pop(ctx);
              },
            ),
            ...models.map((item) {
              bool isCurrent;
              if (currentKey != null) {
                isCurrent =
                    '${item.provider.id}:${item.model.id}' == currentKey;
              } else {
                isCurrent = current != null &&
                    item.provider.id == current.provider.id &&
                    item.model.id == current.model.id;
              }
              return ListTile(
                leading: ModelIcon(
                  providerName: item.provider.name,
                  modelName: item.model.name ?? item.model.id,
                  size: 28,
                ),
                title: Text(item.model.name ?? item.model.id),
                subtitle: Text(item.provider.name),
                trailing: isCurrent ? const Icon(Icons.check) : null,
                onTap: () {
                  onSelect(item.provider.id, item.model.id);
                  Navigator.pop(ctx);
                },
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// 参考 Kelivo _ModelCard：圆角卡片，标题行 + 描述 + 模型选择行
class _ModelCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final ({AiProvider provider, AiModel model})? current;
  final VoidCallback onPick;
  final VoidCallback? onReset;

  const _ModelCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.current,
    required this.onPick,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              Icon(icon, size: 18, color: cs.onSurface),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: onReset != null
                    ? IconButton(
                        icon: Icon(Icons.restart_alt,
                            size: 18, color: cs.onSurfaceVariant),
                        tooltip: AiL10n.current.modelDetailResetAuto,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: onReset,
                      )
                    : null,
              ),
            ],
          ),
          // 描述
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // 模型选择行
          Material(
            color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onPick,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    if (current != null) ...[
                      ModelIcon(
                        providerName: current!.provider.name,
                        modelName:
                            current!.model.name ?? current!.model.id,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: current != null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  current!.model.name ?? current!.model.id,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  current!.provider.name,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              AiL10n.current.notSet,
                              style: TextStyle(
                                fontSize: 14,
                                color:
                                    cs.onSurface.withValues(alpha: 0.4),
                              ),
                            ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
