/// 加解密弹窗共享样式：填充式输入框、消息卡片。
///
/// 解密/加密弹窗共用，避免两个文件重复同一份 decoration。
library;

import 'package:flutter/material.dart';

/// 填充式输入框装饰（无边框 + 圆角 12 + surfaceContainerHighest 填充）。
InputDecoration cryptoSheetInputDecoration(
  ThemeData theme, {
  String? labelText,
  Widget? suffixIcon,
  Widget? prefixIcon,
}) {
  return InputDecoration(
    labelText: labelText,
    suffixIcon: suffixIcon,
    prefixIcon: prefixIcon,
    isDense: true,
    filled: true,
    fillColor: theme.colorScheme.surfaceContainerHigh,
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: theme.colorScheme.primary.withValues(alpha: 0.6),
        width: 1.4,
      ),
    ),
  );
}

/// 弹窗消息卡片（错误提示 / 哈希不可逆提示等）
class CryptoSheetMessageCard extends StatelessWidget {
  const CryptoSheetMessageCard({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// 结果卡片统一容器（明文/密文展示 + 操作按钮）
class CryptoSheetResultCard extends StatelessWidget {
  const CryptoSheetResultCard({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.monospace = false,
    this.maxContentHeight = 220,
  });

  final String title;
  final String content;
  final List<Widget> actions;

  /// 是否用等宽字体展示（密文）
  final bool monospace;
  final double maxContentHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxContentHeight),
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: monospace
                    ? theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace')
                    : theme.textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    );
  }
}
