import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 余额卡片的恢复操作：保留操作文案，处理中显示进度并禁用点击。
class BalanceCardActionButton extends StatelessWidget {
  const BalanceCardActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.isLoading,
    this.filled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isLoading;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final color = filled ? Colors.white : Theme.of(context).colorScheme.primary;
    final icon = isLoading
        ? LoadingSpinner(size: 18, color: color)
        : const Icon(Symbols.refresh_rounded, size: 18);

    if (filled) {
      return FilledButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: icon,
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.2),
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.15),
          disabledForegroundColor: Colors.white70,
        ),
      );
    }

    return TextButton(
      onPressed: isLoading ? null : onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLoading) ...[icon, const SizedBox(width: 8)],
          Text(label),
        ],
      ),
    );
  }
}
