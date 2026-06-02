import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';

/// 弹出"全部 preset"面板（更多 chip 的展开）
///
/// onPick 选完一个 preset 时回调；如果 preset 有 dimensions 会先弹维度面板，
/// 维度选完后再回调。
Future<void> showAiQuickPromptsSheet({
  required BuildContext context,
  required PromptType type,
  required void Function(
    PromptPreset preset,
    Map<String, String>? dimensionValues,
  ) onPick,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _PromptPresetsSheet(type: type, onPick: onPick),
  );
}

/// 弹维度配置面板（preset 有 dimensions 时）
Future<void> showAiPresetDimensionSheet({
  required BuildContext context,
  required PromptPreset preset,
  required void Function(Map<String, String> dimensionValues) onConfirm,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        _DimensionConfigSheet(preset: preset, onConfirm: onConfirm),
  );
}

class _PromptPresetsSheet extends ConsumerWidget {
  const _PromptPresetsSheet({required this.type, required this.onPick});

  final PromptType type;
  final void Function(
    PromptPreset preset,
    Map<String, String>? dimensionValues,
  ) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all = ref.watch(promptPresetsByTypeProvider(type));
    final builtIns = all.where((p) => p.builtIn).toList(growable: false);
    final customs = all.where((p) => !p.builtIn).toList(growable: false);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Text(
                    S.current.ai_quickPromptsTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.tune, size: 16),
                    label: Text(S.current.ai_quickPromptsManage),
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PromptPresetsPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (builtIns.isNotEmpty) ...[
                      _SectionHeader(
                        text: S.current.ai_quickPromptsBuiltInSection,
                      ),
                      ...builtIns.map((p) =>
                          _PresetTile(preset: p, onPick: _onTilePick)),
                    ],
                    if (customs.isNotEmpty) ...[
                      _SectionHeader(
                        text: S.current.ai_quickPromptsCustomSection,
                      ),
                      ...customs.map((p) =>
                          _PresetTile(preset: p, onPick: _onTilePick)),
                    ] else if (customs.isEmpty && builtIns.isNotEmpty) ...[
                      _SectionHeader(
                        text: S.current.ai_quickPromptsCustomSection,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Text(
                          S.current.ai_quickPromptsEmpty,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onTilePick(BuildContext context, PromptPreset preset) {
    if (!preset.hasDimensions) {
      Navigator.of(context).pop();
      onPick(preset, null);
      return;
    }
    Navigator.of(context).pop();
    showAiPresetDimensionSheet(
      context: context,
      preset: preset,
      onConfirm: (dimensionValues) => onPick(preset, dimensionValues),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _PresetTile extends ConsumerWidget {
  const _PresetTile({required this.preset, required this.onPick});

  final PromptPreset preset;
  final void Function(BuildContext context, PromptPreset preset) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onPick(context, preset),
      onLongPress: () => _showActions(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: PresetIcon(
                iconRaw: preset.iconRaw,
                size: 20,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    preset.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (preset.tags.isNotEmpty || preset.aspectRatio != null) ...[
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (preset.aspectRatio != null)
                          _miniBadge(theme, preset.aspectRatio!),
                        for (final t in preset.tags)
                          _miniBadge(theme, t, dim: true),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: preset.pinned
                  ? S.current.ai_quickPromptsUnpin
                  : S.current.ai_quickPromptsPin,
              icon: Icon(
                preset.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 18,
                color: preset.pinned
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              onPressed: () {
                ref
                    .read(promptPresetListProvider.notifier)
                    .togglePin(preset.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBadge(ThemeData theme, String text, {bool dim = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: dim
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10,
          color: dim
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    await showAppBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  preset.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(preset.pinned
                    ? S.current.ai_quickPromptsUnpin
                    : S.current.ai_quickPromptsPin),
                onTap: () {
                  Navigator.of(ctx).pop();
                  ref
                      .read(promptPresetListProvider.notifier)
                      .togglePin(preset.id);
                },
              ),
              if (!preset.builtIn)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(S.current.common_edit),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PromptPresetEditPage(preset: preset),
                      ),
                    );
                  },
                ),
              if (!preset.builtIn)
                ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    S.current.ai_quickPromptsDelete,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error),
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final ok = await _confirmDelete(context, preset.name);
                    if (ok) {
                      await ref
                          .read(promptPresetListProvider.notifier)
                          .deletePreset(preset.id);
                    }
                  },
                ),
              if (preset.builtIn)
                ListTile(
                  leading: Icon(
                    preset.hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  title: Text(preset.hidden
                      ? S.current.ai_quickPromptsUnhide
                      : S.current.ai_quickPromptsHide),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    final notifier =
                        ref.read(promptPresetListProvider.notifier);
                    if (preset.hidden) {
                      notifier.unhide(preset.id);
                    } else {
                      notifier.hide(preset.id);
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(S.current.ai_quickPromptsDeleteConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(S.current.ai_quickPromptsDelete),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// 维度选择 sheet
class _DimensionConfigSheet extends StatefulWidget {
  const _DimensionConfigSheet({required this.preset, required this.onConfirm});

  final PromptPreset preset;
  final void Function(Map<String, String> dimensionValues) onConfirm;

  @override
  State<_DimensionConfigSheet> createState() => _DimensionConfigSheetState();
}

class _DimensionConfigSheetState extends State<_DimensionConfigSheet> {
  late final Map<String, String> _values;

  @override
  void initState() {
    super.initState();
    _values = {...?widget.preset.defaultDimensionValues};
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dimensions = widget.preset.dimensions ?? const [];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.preset.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            for (final dim in dimensions) ...[
              Text(
                dim.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!dim.required)
                    ChoiceChip(
                      label: const Text('—'),
                      selected: !_values.containsKey(dim.id),
                      onSelected: (_) {
                        setState(() => _values.remove(dim.id));
                      },
                    ),
                  for (final opt in dim.options)
                    ChoiceChip(
                      label: Text(opt.label),
                      selected: _values[dim.id] == opt.value,
                      onSelected: (_) {
                        setState(() => _values[dim.id] = opt.value);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(S.current.common_cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onConfirm(_values);
                  },
                  child: Text(S.current.common_confirm),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
