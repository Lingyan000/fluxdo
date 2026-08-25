import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../navigation/nav_action_bus.dart';
import '../../providers/preferences_provider.dart';
import '../../utils/dialog_utils.dart';
import '../settings_model.dart';

/// 底栏设置数据声明
///
/// 只负责"手势"分组（两个动作选择）。布局编辑 UI 在
/// [BottomNavSettingsPage] 内手写，不走数据驱动渲染。
List<SettingsGroup> buildBottomNavGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    SettingsGroup(
      title: l10n.bottomNav_appearanceGroup,
      icon: Symbols.palette_rounded,
      items: [
        SwitchModel(
          id: 'bottomNavLabelless',
          title: l10n.bottomNav_labelless,
          subtitle: l10n.bottomNav_labellessDesc,
          icon: Symbols.label_off_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).bottomNavLabelless,
          onChanged: (ref, value) => ref
              .read(preferencesProvider.notifier)
              .setBottomNavLabelless(value),
        ),
        SwitchModel(
          id: 'bottomNavFloating',
          title: l10n.bottomNav_floating,
          subtitle: l10n.bottomNav_floatingDesc,
          icon: Symbols.dock_to_bottom_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).bottomNavFloating,
          onChanged: (ref, value) => ref
              .read(preferencesProvider.notifier)
              .setBottomNavFloating(value),
        ),
        SwitchModel(
          id: 'bottomNavFloatingBlur',
          title: l10n.bottomNav_floatingBlur,
          subtitle: l10n.bottomNav_floatingBlurDesc,
          icon: Symbols.blur_on_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).bottomNavFloatingBlur,
          onChanged: (ref, value) => ref
              .read(preferencesProvider.notifier)
              .setBottomNavFloatingBlur(value),
          // 仅悬浮底栏开启时显示（前置关闭时展示无意义）
          enabledWhen: (ref) =>
              ref.watch(preferencesProvider).bottomNavFloating,
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.bottomNav_gesturesGroup,
      icon: Symbols.touch_app_rounded,
      items: [
        ActionModel(
          id: 'bottomSingleTapAction',
          title: l10n.bottomNav_singleTapAction,
          subtitle: l10n.bottomNav_singleTapActionDesc,
          icon: Symbols.radio_button_checked_rounded,
          getDynamicSubtitle: (ref) =>
              ref.watch(preferencesProvider).bottomSingleTapAction.label,
          onTap: (ctx, ref) => _pickAction(
            ctx,
            ref,
            isDouble: false,
            current: ref.read(preferencesProvider).bottomSingleTapAction,
          ),
        ),
        ActionModel(
          id: 'bottomDoubleTapAction',
          title: l10n.bottomNav_doubleTapAction,
          subtitle: l10n.bottomNav_doubleTapActionDesc,
          icon: Symbols.double_arrow_rounded,
          getDynamicSubtitle: (ref) =>
              ref.watch(preferencesProvider).bottomDoubleTapAction.label,
          onTap: (ctx, ref) => _pickAction(
            ctx,
            ref,
            isDouble: true,
            current: ref.read(preferencesProvider).bottomDoubleTapAction,
          ),
        ),
      ],
    ),
  ];
}

Future<void> _pickAction(
  BuildContext context,
  WidgetRef ref, {
  required bool isDouble,
  required NavTapAction current,
}) async {
  final chosen = await showAppDialog<NavTapAction>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(dialogContext.l10n.bottomNav_actionPickerTitle),
      children: [
        for (final action in NavTapAction.values)
          _ActionOptionTile(
            action: action,
            selected: action == current,
            onTap: () => Navigator.pop(dialogContext, action),
          ),
      ],
    ),
  );
  if (chosen == null) return;
  final notifier = ref.read(preferencesProvider.notifier);
  if (isDouble) {
    await notifier.setBottomDoubleTapAction(chosen);
  } else {
    await notifier.setBottomSingleTapAction(chosen);
  }
}

class _ActionOptionTile extends StatelessWidget {
  const _ActionOptionTile({
    required this.action,
    required this.selected,
    required this.onTap,
  });

  final NavTapAction action;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = action.icon;
    return ListTile(
      leading: icon != null
          ? Icon(
              icon,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            )
          : Icon(
              Symbols.block_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
      title: Text(action.label),
      trailing: selected
          ? Icon(
              Symbols.check_rounded,
              color: theme.colorScheme.primary,
            )
          : null,
      onTap: onTap,
    );
  }
}
