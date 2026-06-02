import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../models/prompt_preset.dart';
import '../providers/prompt_preset_providers.dart';
import '../widgets/icon_emoji_picker.dart';

const List<String> _kAspectChoices = ['1:1', '16:9', '9:16', '4:3', '3:4'];

/// 快捷词新建/编辑页
///
/// - 新建: 不传 [preset]，可选 [initialType]
/// - 编辑: 传 [preset]
///   - 内置 preset 不可改 name/promptTemplate/icon/dimensions（这些字段
///     UI 仍展示但 disabled），仅可修改 aspectRatio / pinned 等
///   - 自定义 preset 可改全部
class PromptPresetEditPage extends ConsumerStatefulWidget {
  const PromptPresetEditPage({
    super.key,
    this.preset,
    this.initialType = PromptType.image,
  });

  final PromptPreset? preset;
  final PromptType initialType;

  @override
  ConsumerState<PromptPresetEditPage> createState() =>
      _PromptPresetEditPageState();
}

class _PromptPresetEditPageState
    extends ConsumerState<PromptPresetEditPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _templateController;
  late TextEditingController _tagsController;
  late PromptType _type;
  late String _iconRaw;
  String? _aspect;

  bool get _isEditing => widget.preset != null;
  bool get _isBuiltIn => widget.preset?.builtIn ?? false;

  @override
  void initState() {
    super.initState();
    final p = widget.preset;
    _nameController = TextEditingController(text: p?.name ?? '');
    _templateController = TextEditingController(text: p?.promptTemplate ?? '');
    _tagsController = TextEditingController(text: p?.tags.join(', ') ?? '');
    _type = p?.type ?? widget.initialType;
    _iconRaw = p?.iconRaw ?? 'auto_awesome_outlined';
    _aspect = p?.aspectRatio;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _templateController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = _type == PromptType.image;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing
            ? AiL10n.current.quickPromptsEditTitle
            : AiL10n.current.quickPromptsCreateTitle),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(AiL10n.current.save),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 类型
            _Label(text: AiL10n.current.quickPromptsType),
            SegmentedButton<PromptType>(
              segments: [
                ButtonSegment(
                  value: PromptType.image,
                  label: Text(AiL10n.current.quickPromptsTypeImage),
                  icon: const Icon(Icons.image_outlined),
                ),
                ButtonSegment(
                  value: PromptType.text,
                  label: Text(AiL10n.current.quickPromptsTypeText),
                  icon: const Icon(Icons.chat_outlined),
                ),
              ],
              selected: {_type},
              onSelectionChanged: _isBuiltIn
                  ? null
                  : (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),

            // 名称
            _Label(text: AiL10n.current.quickPromptsName),
            TextFormField(
              controller: _nameController,
              enabled: !_isBuiltIn,
              decoration: InputDecoration(
                hintText: AiL10n.current.quickPromptsNameHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) {
                  return AiL10n.current.quickPromptsValidateNameRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // 图标
            _Label(text: AiL10n.current.quickPromptsIcon),
            if (_isBuiltIn)
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _DisabledIconPreview(iconRaw: _iconRaw),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _iconRaw,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              IconEmojiPicker(
                value: _iconRaw,
                onChanged: (v) => setState(() => _iconRaw = v),
              ),
            const SizedBox(height: 16),

            // Prompt 模板
            _Label(text: AiL10n.current.quickPromptsTemplate),
            TextFormField(
              controller: _templateController,
              enabled: !_isBuiltIn,
              minLines: 4,
              maxLines: 12,
              decoration: InputDecoration(
                hintText: AiL10n.current.quickPromptsTemplateHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) {
                  return AiL10n
                      .current.quickPromptsValidateTemplateRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            if (isImage) ...[
              _Label(text: AiL10n.current.quickPromptsAspect),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(AiL10n.current.quickPromptsAspectAuto),
                    selected: _aspect == null,
                    onSelected: (_) => setState(() => _aspect = null),
                  ),
                  for (final a in _kAspectChoices)
                    ChoiceChip(
                      label: Text(a),
                      selected: _aspect == a,
                      onSelected: (_) => setState(() => _aspect = a),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // 标签
            _Label(text: AiL10n.current.quickPromptsTags),
            TextFormField(
              controller: _tagsController,
              enabled: !_isBuiltIn,
              decoration: InputDecoration(
                hintText: AiL10n.current.quickPromptsTagsHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 24),

            if (_isBuiltIn)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '内置快捷词的 name / 模板 / 图标 不可编辑，可调整比例与 Pin/隐藏',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    final template = _templateController.text.trim();
    final tags = _tagsController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    final notifier = ref.read(promptPresetListProvider.notifier);

    if (_isEditing) {
      final base = widget.preset!;
      final updated = base.copyWith(
        name: name,
        promptTemplate: template,
        iconRaw: _iconRaw,
        type: _type,
        tags: tags,
        aspectRatio: _aspect,
        clearAspectRatio: _aspect == null,
      );
      await notifier.updatePreset(updated);
    } else {
      final preset = PromptPreset(
        id: '',
        type: _type,
        name: name,
        iconRaw: _iconRaw,
        promptTemplate: template,
        aspectRatio: _aspect,
        tags: tags,
        pinned: false,
        builtIn: false,
      );
      await notifier.addUserPreset(preset);
    }
    if (mounted) Navigator.of(context).pop();
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _DisabledIconPreview extends StatelessWidget {
  const _DisabledIconPreview({required this.iconRaw});
  final String iconRaw;

  @override
  Widget build(BuildContext context) {
    // 简化版 PresetIcon（只为预览，避免循环导入复杂度）
    if (iconRaw.isNotEmpty && iconRaw.runes.first >= 0x80) {
      return Text(iconRaw, style: const TextStyle(fontSize: 22));
    }
    return const Icon(Icons.auto_awesome_outlined, size: 22);
  }
}
