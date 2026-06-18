import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:common_ui/common_ui.dart';
import '../../../l10n/s.dart';

/// 上下文范围选择器
class AiContextSelector extends StatelessWidget {
  final ContextScope currentScope;
  final ValueChanged<ContextScope> onChanged;

  const AiContextSelector({
    super.key,
    required this.currentScope,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SwipeDismissiblePopupMenuButton<ContextScope>(
      tooltip: context.l10n.ai_selectContext,
      initialValue: currentScope,
      onSelected: onChanged,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              currentScope.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
      itemBuilder: (context) => ContextScope.values.map((scope) {
        return PopupMenuItem<ContextScope>(
          value: scope,
          child: Row(
            children: [
              if (scope == currentScope)
                Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
              else
                const SizedBox(width: 18),
              const SizedBox(width: 8),
              Text(scope.label),
            ],
          ),
        );
      }).toList(),
    );
  }
}
