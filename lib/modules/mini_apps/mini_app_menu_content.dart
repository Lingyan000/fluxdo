import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../utils/adaptive_menu.dart';

/// 公共菜单外壳内的紧凑操作面板：常用动作、支持作者、其余工具分组呈现。
class MiniAppMenuContent<T> extends StatelessWidget {
  const MiniAppMenuContent({
    super.key,
    required this.quick,
    required this.community,
    required this.utilities,
  });
  final List<AdaptiveMenuItem<T>> quick, community, utilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    Widget tile(AdaptiveMenuItem<T> item, {bool prominent = false}) =>
        SegmentedCardItem(
          index: 0,
          count: 1,
          outerRadius: prominent ? 24 : 18,
          child: InkWell(
            onTap: () => Navigator.pop(context, item.value),
            child: Padding(
              padding: EdgeInsets.all(prominent ? 16 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        item.icon,
                        size: prominent ? 26 : 21,
                        color: item.destructive ? colors.error : colors.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.label,
                          style:
                              (prominent
                                      ? theme.textTheme.titleSmall
                                      : theme.textTheme.labelLarge)
                                  ?.copyWith(
                                    color: item.destructive
                                        ? colors.error
                                        : null,
                                  ),
                        ),
                      ),
                    ],
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      item.subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
    Widget grid(List<AdaptiveMenuItem<T>> items, {bool prominent = false}) =>
        LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                constraints.maxWidth < 320 ||
                    MediaQuery.textScalerOf(context).scale(1) > 1.5
                ? 1
                : 2;
            return Column(
              children: [
                for (var row = 0; row < items.length; row += columns) ...[
                  if (row > 0) const SizedBox(height: 6),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var column = 0; column < columns; column++) ...[
                          if (column > 0) const SizedBox(width: 6),
                          Expanded(
                            child: row + column < items.length
                                ? tile(
                                    items[row + column],
                                    prominent: prominent,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  MediaQuery.textScalerOf(context).scale(1) > 1.4 ||
                      constraints.maxWidth < 300
                  ? 2
                  : quick.length.clamp(1, 4);
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final item in quick)
                    SizedBox(
                      width:
                          (constraints.maxWidth - (columns - 1) * 6) / columns,
                      child: SegmentedCardItem(
                        index: 0,
                        count: 1,
                        outerRadius: 22,
                        child: InkWell(
                          onTap: () => Navigator.pop(context, item.value),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 14,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  item.icon,
                                  size: 25,
                                  color: colors.primary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.label,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (community.isNotEmpty) ...[
            heading(context.l10n.miniApp_supportDeveloper),
            grid(community, prominent: true),
          ],
          if (utilities.isNotEmpty) ...[
            heading(context.l10n.miniApp_moreActions),
            grid(utilities),
          ],
        ],
      ),
    );
  }
}
