import 'package:flutter/material.dart';

/// 平行视界右栏空态占位(统一形态,语义由调用方给)。
///
/// 对齐搜索页 _buildParallelEmptyState 的做法:显式铺 scaffold 背景色,
/// 否则空详情栏会透出 MaterialApp 默认 canvasColor,与左栏形成色断层。
class PaneEmptyState extends StatelessWidget {
  const PaneEmptyState({super.key, required this.icon, required this.hint});

  final IconData icon;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(
              hint,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
