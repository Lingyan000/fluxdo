import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import '../../l10n/s.dart';

/// 文档操作始终直接显示，保留稳定的点击区域。
class ComposerActionButton extends StatelessWidget {
  const ComposerActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.busy = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    padding: const EdgeInsets.all(10),
    style: IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      maximumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 21),
  );
}

class ComposerDiscardButton extends StatelessWidget {
  const ComposerDiscardButton({super.key, this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => ComposerActionButton(
    icon: Symbols.delete_rounded,
    label: S.current.common_discard,
    onPressed: onPressed,
  );
}

/// 可切换的创建页标题，继承 AppBar 的标题样式。
class ComposerTopicKindPicker extends StatelessWidget {
  const ComposerTopicKindPicker({
    super.key,
    required this.question,
    required this.onChanged,
    this.enabled = true,
    this.locked = false,
  });
  final bool question;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = question
        ? S.current.composer_kindQuestion
        : S.current.composer_kindTopic;
    return SwipeDismissiblePopupMenuButton<bool>(
      enabled: enabled && !locked,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(8),
      tooltip: '',
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 220),
      color: colors.surfaceContainer,
      elevation: 3,
      shadowColor: colors.shadow.withValues(alpha: .24),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: .45),
          width: .6,
        ),
      ),
      // 不传 initialValue：Flutter 会用它将选中行居中到触发点，从而覆盖入口。
      // 当前项的勾选标识由菜单内容自行绘制。
      onSelected: (value) {
        if (value != question) onChanged(value);
      },
      itemBuilder: (_) => [
        for (final value in [false, true])
          PopupMenuItem<bool>(
            key: ValueKey('composer-kind-option-$value'),
            value: value,
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value
                        ? S.current.composer_kindQuestion
                        : S.current.composer_kindTopic,
                  ),
                ),
                if (value == question)
                  Icon(Symbols.check_rounded, size: 18, color: colors.primary),
              ],
            ),
          ),
      ],
      child: SizedBox(
        key: const ValueKey('composer-kind-trigger'),
        height: 44,
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          // 箭头参与标题的自然省略，窄屏优先保留标题文字。
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: label),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      locked
                          ? Symbols.lock_rounded
                          : Symbols.expand_more_rounded,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            key: const ValueKey('composer-title-label'),
            semanticsLabel: label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
