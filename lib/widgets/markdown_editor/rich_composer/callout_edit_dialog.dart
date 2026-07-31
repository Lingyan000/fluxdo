/// Obsidian Callout 属性对话框(插入与壳编辑共用):类型网格 +
/// 可选标题 + 折叠三态(静态 / `+` 默认展开 / `-` 默认折叠)。
library;

import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../utils/dialog_utils.dart';

/// 官方常用类型(与 MD 工具栏 callout 菜单一致;渲染端 CalloutKind
/// 全兼容,别名如 abstract→summary 由 fromType 归一)。
const kCalloutTypes = [
  'note',
  'tip',
  'info',
  'warning',
  'danger',
  'bug',
  'example',
  'quote',
  'abstract',
  'todo',
  'success',
  'question',
  'failure',
];

/// 对话框结果。
class CalloutSpec {
  const CalloutSpec({
    required this.type,
    required this.title,
    required this.foldable,
  });

  final String type;

  /// 空串 = 无自定义标题(渲染端按类型名出标题)。
  final String title;

  /// null = 静态;true = 可折叠默认展开(`+`);false = 默认折叠(`-`)。
  final bool? foldable;

  /// 组装 Obsidian 语法首行(`[!type]±  标题`)。
  String get headerMarkdown {
    final fold = switch (foldable) {
      true => '+',
      false => '-',
      null => '',
    };
    final t = title.trim();
    return '[!$type]$fold${t.isEmpty ? '' : ' $t'}';
  }
}

Future<CalloutSpec?> showCalloutEditDialog(
  BuildContext context, {
  String type = 'note',
  String title = '',
  bool? foldable,
}) {
  return showAppDialog<CalloutSpec>(
    context: context,
    builder: (_) => _CalloutEditDialog(
      initialType: type,
      initialTitle: title,
      initialFoldable: foldable,
    ),
  );
}

class _CalloutEditDialog extends StatefulWidget {
  const _CalloutEditDialog({
    required this.initialType,
    required this.initialTitle,
    required this.initialFoldable,
  });

  final String initialType;
  final String initialTitle;
  final bool? initialFoldable;

  @override
  State<_CalloutEditDialog> createState() => _CalloutEditDialogState();
}

class _CalloutEditDialogState extends State<_CalloutEditDialog> {
  late String _type = widget.initialType;
  late bool? _foldable = widget.initialFoldable;
  // controller 必须归对话框 State(pop 后宿主立即 dispose 会撞退场动画)
  late final TextEditingController _title = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 初值可能是清单外的自定义类型(如 [!whatever]):保留为候选
    final types = kCalloutTypes.contains(_type)
        ? kCalloutTypes
        : [_type, ...kCalloutTypes];
    return AlertDialog(
      title: const Text('标注(Callout)'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in types)
                    ChoiceChip(
                      label: Text(t, style: const TextStyle(fontSize: 12)),
                      selected: _type == t,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '标题(可空,默认按类型名)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              M3eButtonGroup<int>(
                items: const [
                  M3eButtonGroupItem(value: 0, label: Text('静态')),
                  M3eButtonGroupItem(value: 1, label: Text('可折叠')),
                  M3eButtonGroupItem(value: 2, label: Text('默认折叠')),
                ],
                selected: switch (_foldable) {
                  null => 0,
                  true => 1,
                  false => 2,
                },
                onSelected: (v) => setState(
                  () => _foldable = switch (v) {
                    0 => null,
                    1 => true,
                    _ => false,
                  },
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '可折叠 = [!$_type]+ / 默认折叠 = [!$_type]-',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            CalloutSpec(type: _type, title: _title.text, foldable: _foldable),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
