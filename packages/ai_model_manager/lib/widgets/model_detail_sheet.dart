import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_provider.dart';
import '../services/toast_delegate.dart';
import '../utils/model_capabilities.dart';

/// 编辑已有模型，返回编辑后的 [AiModel]，取消返回 null。
Future<AiModel?> showModelDetailSheet(
  BuildContext context, {
  required AiModel model,
}) {
  return showModalBottomSheet<AiModel>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _ModelDetailSheet(model: model, isNew: false),
      ),
    ),
  );
}

/// 新建模型，返回创建的 [AiModel]，取消返回 null。
Future<AiModel?> showCreateModelSheet(BuildContext context) {
  return showModalBottomSheet<AiModel>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: const _ModelDetailSheet(model: null, isNew: true),
      ),
    ),
  );
}

class _ModelDetailSheet extends StatefulWidget {
  const _ModelDetailSheet({required this.model, required this.isNew});

  final AiModel? model;
  final bool isNew;

  @override
  State<_ModelDetailSheet> createState() => _ModelDetailSheetState();
}

class _ModelDetailSheetState extends State<_ModelDetailSheet> {
  late TextEditingController _idCtrl;
  late TextEditingController _nameCtrl;
  bool _nameEdited = false;
  bool _showAdvanced = false;

  final Set<Modality> _input = {};
  final Set<Modality> _output = {};
  final Set<ModelAbility> _abilities = {};

  bool _userEdited = false;

  @override
  void initState() {
    super.initState();
    final m = widget.model;
    _idCtrl = TextEditingController(text: m?.id ?? '');
    _nameCtrl = TextEditingController(text: m?.name ?? '');
    if (m != null) {
      _input.addAll(m.input);
      _output.addAll(m.output);
      _abilities.addAll(m.abilities);
      _userEdited = m.capabilitiesUserEdited;
      _showAdvanced = true;
    } else {
      _input.add(Modality.text);
      _output.add(Modality.text);
    }
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _inferFromId() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) return;
    final inferred = ModelCapabilities.infer(AiModel(id: id));
    setState(() {
      _input
        ..clear()
        ..addAll(inferred.input);
      _output
        ..clear()
        ..addAll(inferred.output);
      _abilities
        ..clear()
        ..addAll(inferred.abilities);
    });
  }

  void _save() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.modelDetailIdRequired);
      return;
    }
    final inputList = _input.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final outputList = _output.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final abilitiesList = _abilities.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final name = _nameCtrl.text.trim();
    final result = AiModel(
      id: id,
      name: name.isEmpty ? null : name,
      enabled: widget.model?.enabled ?? true,
      input: inputList,
      output: outputList,
      abilities: abilitiesList,
      capabilitiesUserEdited: _userEdited,
    );
    Navigator.of(context).pop(result);
  }

  void _resetToAuto() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) return;
    final inferred = ModelCapabilities.infer(AiModel(id: id));
    setState(() {
      _input
        ..clear()
        ..addAll(inferred.input);
      _output
        ..clear()
        ..addAll(inferred.output);
      _abilities
        ..clear()
        ..addAll(inferred.abilities);
      _userEdited = false;
    });
    AiToastDelegate.showInfo(AiL10n.current.capabilityResetSnack);
  }

  void _markEdited() {
    if (!_userEdited) setState(() => _userEdited = true);
  }

  InputDecoration _inputDeco(BuildContext context, String? hint,
      {Widget? suffix}) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InputDecoration(
      filled: true,
      fillColor: isDark ? Colors.white10 : cs.surfaceContainerLow,
      hintText: hint,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5)),
      ),
      suffixIcon: suffix,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNew = widget.isNew;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: isNew && !_showAdvanced ? 0.45 : 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.3,
      builder: (c, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.close, color: cs.onSurface, size: 22),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: AiL10n.current.cancel,
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        isNew
                            ? AiL10n.current.modelDetailAddTitle
                            : AiL10n.current.modelDetailTitle,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                children: [
                  // 模型 ID
                  _label(context, AiL10n.current.modelDetailIdLabel),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _idCtrl,
                    readOnly: !isNew,
                    autofocus: isNew,
                    style: TextStyle(
                      color: isNew
                          ? null
                          : cs.onSurface.withValues(alpha: 0.6),
                    ),
                    onChanged: isNew
                        ? (v) {
                            if (!_nameEdited) _nameCtrl.text = v;
                            _inferFromId();
                          }
                        : null,
                    decoration: _inputDeco(
                      context,
                      AiL10n.current.modelDetailIdHint,
                      suffix: isNew
                          ? null
                          : _CopyButton(
                              onTap: () {
                                final text = _idCtrl.text.trim();
                                if (text.isEmpty) return;
                                Clipboard.setData(ClipboardData(text: text));
                                AiToastDelegate.showSuccess(
                                    AiL10n.current.modelDetailIdCopied);
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 显示名称
                  _label(context, AiL10n.current.modelDetailNameLabel),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _nameCtrl,
                    onChanged: (_) {
                      if (!_nameEdited) setState(() => _nameEdited = true);
                    },
                    decoration: _inputDeco(context, null),
                  ),
                  // 能力标签预览（新建模式折叠时）
                  if (isNew && !_showAdvanced) ...[
                    const SizedBox(height: 16),
                    _CapabilityPreview(
                      input: _input,
                      output: _output,
                      abilities: _abilities,
                      onExpand: () =>
                          setState(() => _showAdvanced = true),
                    ),
                  ],
                  // 能力编辑区
                  if (_showAdvanced) ...[
                    const SizedBox(height: 20),
                    _label(context, AiL10n.current.modelDetailInputLabel),
                    const SizedBox(height: 6),
                    _SegmentedMulti(
                      options: [
                        AiL10n.current.modelDetailTextMode,
                        AiL10n.current.modelDetailImageMode,
                      ],
                      isSelected: [
                        _input.contains(Modality.text),
                        _input.contains(Modality.image),
                      ],
                      onChanged: (idx) {
                        setState(() {
                          final mod =
                              idx == 0 ? Modality.text : Modality.image;
                          if (_input.contains(mod)) {
                            _input.remove(mod);
                            if (_input.isEmpty) _input.add(Modality.text);
                          } else {
                            _input.add(mod);
                          }
                        });
                        _markEdited();
                      },
                    ),
                    const SizedBox(height: 12),
                    _label(context, AiL10n.current.modelDetailOutputLabel),
                    const SizedBox(height: 6),
                    _SegmentedMulti(
                      options: [
                        AiL10n.current.modelDetailTextMode,
                        AiL10n.current.modelDetailImageMode,
                      ],
                      isSelected: [
                        _output.contains(Modality.text),
                        _output.contains(Modality.image),
                      ],
                      onChanged: (idx) {
                        setState(() {
                          final mod =
                              idx == 0 ? Modality.text : Modality.image;
                          if (_output.contains(mod)) {
                            _output.remove(mod);
                            if (_output.isEmpty) _output.add(Modality.text);
                          } else {
                            _output.add(mod);
                          }
                        });
                        _markEdited();
                      },
                    ),
                    const SizedBox(height: 12),
                    _label(
                        context, AiL10n.current.modelDetailAbilitiesLabel),
                    const SizedBox(height: 6),
                    _SegmentedMulti(
                      options: [
                        AiL10n.current.modelDetailToolAbility,
                        AiL10n.current.modelDetailReasoningAbility,
                      ],
                      isSelected: [
                        _abilities.contains(ModelAbility.tool),
                        _abilities.contains(ModelAbility.reasoning),
                      ],
                      allowEmpty: true,
                      onChanged: (idx) {
                        setState(() {
                          final ab = idx == 0
                              ? ModelAbility.tool
                              : ModelAbility.reasoning;
                          if (_abilities.contains(ab)) {
                            _abilities.remove(ab);
                          } else {
                            _abilities.add(ab);
                          }
                        });
                        _markEdited();
                      },
                    ),
                    if (_userEdited) ...[
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton.icon(
                          onPressed: _resetToAuto,
                          icon: const Icon(Icons.restart_alt, size: 18),
                          label:
                              Text(AiL10n.current.modelDetailResetAuto),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
            // 底部确认按钮
            Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 10 + MediaQuery.of(context).padding.bottom),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: Icon(isNew ? Icons.add : Icons.check, size: 20),
                  label: Text(
                    isNew
                        ? AiL10n.current.modelDetailAddTitle
                        : AiL10n.current.modelDetailConfirm,
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
        ),
      );
}

/// 新建模式的能力预览条：展示自动推断结果 + 展开按钮
class _CapabilityPreview extends StatelessWidget {
  const _CapabilityPreview({
    required this.input,
    required this.output,
    required this.abilities,
    required this.onExpand,
  });

  final Set<Modality> input;
  final Set<Modality> output;
  final Set<ModelAbility> abilities;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chips = <Widget>[];

    String modName(Modality m) => m == Modality.text
        ? AiL10n.current.modelDetailTextMode
        : AiL10n.current.modelDetailImageMode;

    for (final m in input) {
      if (m == Modality.image) {
        chips.add(_miniChip(
            '${AiL10n.current.modelDetailInputLabel}: ${modName(m)}',
            cs.tertiary,
            isDark));
      }
    }
    for (final m in output) {
      if (m == Modality.image) {
        chips.add(_miniChip(
            '${AiL10n.current.modelDetailOutputLabel}: ${modName(m)}',
            cs.secondary,
            isDark));
      }
    }
    for (final a in abilities) {
      final label = a == ModelAbility.tool
          ? AiL10n.current.modelDetailToolAbility
          : AiL10n.current.modelDetailReasoningAbility;
      chips.add(_miniChip(label, cs.primary, isDark));
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onExpand,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: chips.isEmpty
                  ? Text(
                      AiL10n.current.modelDetailAbilitiesLabel,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    )
                  : Wrap(spacing: 6, runSpacing: 4, children: chips),
            ),
            Icon(Icons.tune, size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _miniChip(String label, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark
            ? color.withValues(alpha: 0.2)
            : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? color : color.withValues(alpha: 0.9),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 参考 Kelivo _SegmentedMulti：多选分段控件
class _SegmentedMulti extends StatelessWidget {
  const _SegmentedMulti({
    required this.options,
    required this.isSelected,
    required this.onChanged,
    this.allowEmpty = false,
  });

  final List<String> options;
  final List<bool> isSelected;
  final ValueChanged<int> onChanged;
  final bool allowEmpty;

  @override
  Widget build(BuildContext context) {
    assert(options.length == isSelected.length);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool allSelected =
        isSelected.isNotEmpty && isSelected.every((e) => e);

    final base = isDark ? Colors.white10 : const Color(0xFFF2F3F5);
    final sel = isDark
        ? cs.primary.withValues(alpha: 0.20)
        : cs.primary.withValues(alpha: 0.14);
    final r = BorderRadius.circular(12);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        color: base,
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(
          children: [
            if (allSelected)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(color: sel, borderRadius: r),
                ),
              ),
            Row(
              children: [
                for (int i = 0; i < options.length; i++)
                  Expanded(
                    child: InkWell(
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      onTap: () => onChanged(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: allSelected
                              ? Colors.transparent
                              : (isSelected[i] ? sel : Colors.transparent),
                          borderRadius: _borderRadiusFor(i, options.length),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (isSelected[i])
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.check,
                                  size: 16,
                                  color: cs.primary,
                                ),
                              ),
                            Text(
                              options[i],
                              style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  BorderRadius _borderRadiusFor(int index, int total) {
    const r = Radius.circular(12);
    if (total == 1) return BorderRadius.all(r);
    if (index == 0) {
      return const BorderRadius.only(topLeft: r, bottomLeft: r);
    }
    if (index == total - 1) {
      return const BorderRadius.only(topRight: r, bottomRight: r);
    }
    return BorderRadius.zero;
  }
}

/// 复制按钮（TextField suffixIcon），带 hover/pressed 动画
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.onSurface.withValues(alpha: 0.9);
    final bg = _pressed
        ? cs.onSurface.withValues(alpha: 0.12)
        : (_hover ? cs.onSurface.withValues(alpha: 0.08) : Colors.transparent);

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.copy, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}
