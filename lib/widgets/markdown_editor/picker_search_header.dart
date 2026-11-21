import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../../l10n/s.dart';

/// 表情 / 表情包搜索的输入头部(底部弹层形态)。
///
/// 两个面板共用,保证搜索的形态一致:圆角输入框 + 「取消」,下方细分隔线。
/// 「取消」关闭所在弹层。
class PickerSearchSheetHeader extends StatelessWidget {
  const PickerSearchSheetHeader({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.showClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;

  /// 是否显示清空按钮(调用方按当前查询词决定)。
  final bool showClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: InputFieldShell(
              height: 44,
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              radius: 12,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textAlignVertical: TextAlignVertical.center,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.only(left: 0, right: 12),
                  prefixIcon: Icon(
                    Symbols.search_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurface,
                  ),
                  suffixIcon: showClear
                      ? IconButton(
                          icon: const Icon(Symbols.cancel_rounded, size: 18),
                          color: theme.colorScheme.onSurfaceVariant,
                          onPressed: controller.clear,
                        )
                      : null,
                ).withoutBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              FocusScope.of(context).unfocus();
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(S.current.common_cancel),
          ),
        ],
      ),
    );
  }
}

/// 表情 / 表情包搜索的输入头部(面板内联形态,桌面悬浮面板用)。
///
/// 返回按钮 + 紧凑输入框,进入即聚焦。
class PickerSearchInlineHeader extends StatelessWidget {
  const PickerSearchInlineHeader({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.showClear,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final bool showClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Symbols.arrow_back_rounded, size: 20),
            color: theme.colorScheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            tooltip: S.current.common_cancel,
          ),
          Expanded(
            child: InputFieldShell(
              height: 36,
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              radius: 10,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textAlignVertical: TextAlignVertical.center,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.only(right: 12),
                  prefixIcon: Icon(
                    Symbols.search_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  suffixIcon: showClear
                      ? IconButton(
                          icon: const Icon(Symbols.cancel_rounded, size: 16),
                          color: theme.colorScheme.onSurfaceVariant,
                          onPressed: controller.clear,
                        )
                      : null,
                ).withoutBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 搜索的空态:可选图标 + 提示文字。
class PickerSearchMessage extends StatelessWidget {
  const PickerSearchMessage(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Text(
      text,
      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
    );
    if (icon == null) return Center(child: label);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 48,
            color: theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          label,
        ],
      ),
    );
  }
}
