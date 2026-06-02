import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../l10n/ai_l10n.dart';
import '../models/prompt_preset.dart';
import '../providers/prompt_preset_providers.dart';
import '../services/toast_delegate.dart';
import '../utils/dialog_utils.dart';
import '../widgets/preset_icon.dart';
import '../widgets/swipe_action_cell.dart';
import 'prompt_preset_edit_page.dart';

/// 快捷词管理页
///
/// - 顶部 segmented：图像 / 文本
/// - 列表分两段：内置 / 自定义
/// - 拖拽排序（分组内）
/// - swipe 编辑/删除/隐藏
/// - 右上 + 新建；溢出菜单 恢复内置默认
class PromptPresetsPage extends ConsumerStatefulWidget {
  const PromptPresetsPage({super.key, this.initialType = PromptType.image});

  final PromptType initialType;

  @override
  ConsumerState<PromptPresetsPage> createState() =>
      _PromptPresetsPageState();
}

class _PromptPresetsPageState extends ConsumerState<PromptPresetsPage> {
  late PromptType _type;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = ref.watch(promptPresetsByTypeProvider(_type));
    final builtIns = all.where((p) => p.builtIn).toList(growable: false);
    final customs = all.where((p) => !p.builtIn).toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(AiL10n.current.quickPromptsManageTitle),
        actions: [
          IconButton(
            tooltip: AiL10n.current.quickPromptsAddNew,
            icon: const Icon(Icons.add),
            onPressed: _addNew,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'reset':
                  _confirmReset();
                case 'export_all':
                  _exportAll(customs);
                case 'import':
                  _importFromClipboard();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.paste_outlined, size: 20),
                  title: Text(AiL10n.current.presetImport),
                ),
              ),
              if (customs.isNotEmpty)
                PopupMenuItem(
                  value: 'export_all',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading:
                        const Icon(Icons.file_upload_outlined, size: 20),
                    title: Text(AiL10n.current.presetExportAll),
                  ),
                ),
              PopupMenuItem(
                value: 'reset',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.restart_alt_outlined, size: 20),
                  title: Text(AiL10n.current.quickPromptsResetBuiltIns),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<PromptType>(
              segments: [
                ButtonSegment(
                  value: PromptType.image,
                  label: Text(AiL10n.current.quickPromptsImageTab),
                  icon: const Icon(Icons.image_outlined),
                ),
                ButtonSegment(
                  value: PromptType.text,
                  label: Text(AiL10n.current.quickPromptsTextTab),
                  icon: const Icon(Icons.chat_outlined),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SwipeActionScope(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  if (builtIns.isNotEmpty) ...[
                    _SectionLabel(text: AiL10n.current.quickPromptsBuiltInSection),
                    _ReorderableGroup(
                      presets: builtIns,
                      type: _type,
                      builtIn: true,
                      onEdit: _openEdit,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _SectionLabel(text: AiL10n.current.quickPromptsCustomSection),
                  if (customs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        AiL10n.current.quickPromptsEmpty,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    _ReorderableGroup(
                      presets: customs,
                      type: _type,
                      builtIn: false,
                      onEdit: _openEdit,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addNew() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PromptPresetEditPage(initialType: _type),
      ),
    );
  }

  void _openEdit(PromptPreset preset) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PromptPresetEditPage(preset: preset),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(AiL10n.current.quickPromptsResetBuiltInsConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AiL10n.current.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AiL10n.current.quickPromptsResetBuiltIns),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref
          .read(promptPresetListProvider.notifier)
          .resetBuiltInsToDefault();
    }
  }

  // ────────────── 导入/导出 ──────────────

  static Map<String, dynamic> _presetToExport(PromptPreset p) => {
        'type': p.type.toJson(),
        'name': p.name,
        'iconRaw': p.iconRaw,
        'promptTemplate': p.promptTemplate,
        if (p.aspectRatio != null) 'aspectRatio': p.aspectRatio,
        if (p.tags.isNotEmpty) 'tags': p.tags,
        if (p.dimensions != null)
          'dimensions': p.dimensions!.map((d) => d.toJson()).toList(),
        if (p.defaultDimensionValues != null)
          'defaultDimensionValues': p.defaultDimensionValues,
      };

  static void exportPreset(PromptPreset preset) {
    final json = jsonEncode({
      'version': 1,
      'presets': [_presetToExport(preset)],
    });
    Clipboard.setData(ClipboardData(text: json));
    AiToastDelegate.showSuccess(AiL10n.current.presetExportSuccess);
  }

  void _exportAll(List<PromptPreset> customs) {
    if (customs.isEmpty) return;
    final json = jsonEncode({
      'version': 1,
      'presets': customs.map(_presetToExport).toList(),
    });
    Clipboard.setData(ClipboardData(text: json));
    AiToastDelegate.showSuccess(AiL10n.current.presetExportSuccess);
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.presetImportEmpty);
      return;
    }

    List<PromptPreset> parsed;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        final list = json['presets'] as List<dynamic>?;
        if (list == null || list.isEmpty) throw FormatException('no presets');
        parsed = list
            .map((e) => PromptPreset.fromJson(e as Map<String, dynamic>))
            .toList();
      } else if (json is List) {
        parsed = json
            .map((e) => PromptPreset.fromJson(e as Map<String, dynamic>))
            .toList();
      } else {
        throw FormatException('invalid format');
      }
    } catch (_) {
      AiToastDelegate.showError(AiL10n.current.presetImportEmpty);
      return;
    }

    if (parsed.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.presetImportEmpty);
      return;
    }

    if (!mounted) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AiL10n.current.presetImportPreview),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: parsed.length,
            itemBuilder: (_, i) {
              final p = parsed[i];
              return ListTile(
                leading: PresetIcon(iconRaw: p.iconRaw, size: 28),
                title: Text(p.name),
                subtitle: Text(p.type == PromptType.image
                    ? AiL10n.current.quickPromptsImageTab
                    : AiL10n.current.quickPromptsTextTab),
                dense: true,
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AiL10n.current.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AiL10n.current.presetImportConfirm),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    const uuid = Uuid();
    final notifier = ref.read(promptPresetListProvider.notifier);
    var count = 0;
    for (final p in parsed) {
      await notifier.addUserPreset(p.copyWith(
        id: uuid.v4(),
        builtIn: false,
        hidden: false,
        pinned: false,
        sortOrder: 999 + count,
      ));
      count++;
    }
    AiToastDelegate.showSuccess(AiL10n.current.presetImportCount(count));
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
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

class _ReorderableGroup extends ConsumerStatefulWidget {
  const _ReorderableGroup({
    required this.presets,
    required this.type,
    required this.builtIn,
    required this.onEdit,
  });

  final List<PromptPreset> presets;
  final PromptType type;
  final bool builtIn;
  final void Function(PromptPreset) onEdit;

  @override
  ConsumerState<_ReorderableGroup> createState() =>
      _ReorderableGroupState();
}

class _ReorderableGroupState extends ConsumerState<_ReorderableGroup> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.presets.length,
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) async {
        final ids = [for (final p in widget.presets) p.id];
        final id = ids.removeAt(oldIndex);
        ids.insert(newIndex, id);
        await ref
            .read(promptPresetListProvider.notifier)
            .reorderInGroup(widget.type, widget.builtIn, ids);
      },
      itemBuilder: (context, index) {
        final preset = widget.presets[index];
        return Padding(
          key: ValueKey(preset.id),
          padding: const EdgeInsets.only(bottom: 8),
          child: SwipeActionCell(
            key: ValueKey('swipe_${preset.id}'),
            trailingActions: [
              if (!preset.builtIn)
                SwipeAction(
                  icon: Icons.edit_outlined,
                  color: Colors.blue,
                  label: AiL10n.current.edit,
                  onPressed: () => widget.onEdit(preset),
                ),
              if (preset.builtIn)
                SwipeAction(
                  icon: preset.hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: Colors.orange,
                  label: preset.hidden
                      ? AiL10n.current.quickPromptsUnhide
                      : AiL10n.current.quickPromptsHide,
                  onPressed: () {
                    final notifier =
                        ref.read(promptPresetListProvider.notifier);
                    if (preset.hidden) {
                      notifier.unhide(preset.id);
                    } else {
                      notifier.hide(preset.id);
                    }
                  },
                ),
              if (!preset.builtIn)
                SwipeAction(
                  icon: Icons.copy_outlined,
                  color: Colors.teal,
                  label: AiL10n.current.presetExport,
                  onPressed: () => _PromptPresetsPageState.exportPreset(preset),
                ),
              if (!preset.builtIn)
                SwipeAction(
                  icon: Icons.delete_outline,
                  color: Colors.red,
                  label: AiL10n.current.delete,
                  onPressed: () async {
                    final ok = await _confirmDelete(context, preset.name);
                    if (ok) {
                      await ref
                          .read(promptPresetListProvider.notifier)
                          .deletePreset(preset.id);
                    }
                  },
                ),
            ],
            child: Card(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: InkWell(
                onTap: !preset.builtIn ? () => widget.onEdit(preset) : null,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.drag_indicator,
                            color:
                                theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
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
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    preset.name,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: preset.hidden
                                          ? theme.colorScheme.onSurfaceVariant
                                          : null,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (preset.hidden) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.visibility_off_outlined,
                                    size: 14,
                                    color:
                                        theme.colorScheme.onSurfaceVariant,
                                  ),
                                ],
                              ],
                            ),
                            if (preset.tags.isNotEmpty ||
                                preset.aspectRatio != null) ...[
                              const SizedBox(height: 2),
                              Wrap(
                                spacing: 4,
                                runSpacing: 2,
                                children: [
                                  if (preset.aspectRatio != null)
                                    _badge(theme, preset.aspectRatio!),
                                  for (final t in preset.tags)
                                    _badge(theme, t, dim: true),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: preset.pinned
                            ? AiL10n.current.quickPromptsUnpin
                            : AiL10n.current.quickPromptsPin,
                        icon: Icon(
                          preset.pinned
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
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
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _badge(ThemeData theme, String text, {bool dim = false}) {
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

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(AiL10n.current.quickPromptsDeleteConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AiL10n.current.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(AiL10n.current.delete),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
