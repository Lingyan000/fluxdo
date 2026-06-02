import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import 'settings_model.dart';

/// 根据 SettingsModel 类型分派到对应的 Widget
class SettingsRenderer extends ConsumerWidget {
  final SettingsModel model;

  const SettingsRenderer({super.key, required this.model});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return switch (model) {
      SwitchModel m => _buildSwitch(context, ref, theme, m),
      DoubleSliderModel m => _buildDoubleSlider(context, ref, theme, m),
      IntSliderModel m => _buildIntSlider(context, ref, theme, m),
      ActionModel m => _buildAction(context, ref, theme, m),
      CustomModel m => m.builder(context, ref),
      PlatformConditionalModel m => m.shouldShow
          ? SettingsRenderer(model: m.inner)
          : const SizedBox.shrink(),
    };
  }

  Widget _buildSwitch(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    SwitchModel m,
  ) {
    final value = m.getValue(ref);
    return SwitchListTile(
      title: Text(m.title),
      subtitle: m.subtitle != null ? Text(m.subtitle!) : null,
      secondary: Icon(
        m.icon,
        color: value
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      value: value,
      onChanged: (v) => m.onChanged(ref, v),
    );
  }

  Widget _buildDoubleSlider(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    DoubleSliderModel m,
  ) {
    final value = m.getValue(ref);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(m.icon, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.title),
                    Text(
                      m.labelBuilder(value),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (m.onReset != null)
                TextButton(
                  onPressed: value != ((m.min + m.max) / 2).roundToDouble()
                      ? () => m.onReset!(ref)
                      : null,
                  child: Text(context.l10n.common_reset),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value,
              min: m.min,
              max: m.max,
              divisions: m.divisions,
              label: m.labelBuilder(value),
              onChanged: (v) => m.onChanged(ref, v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntSlider(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    IntSliderModel m,
  ) {
    final value = m.getValue(ref);
    final suffix = m.valueSuffix ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(m.icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.title, style: theme.textTheme.bodyMedium),
                if (m.subtitle != null)
                  Text(
                    m.subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                Slider(
                  value: value.toDouble(),
                  min: m.min.toDouble(),
                  max: m.max.toDouble(),
                  divisions: m.max - m.min,
                  label: '$value$suffix',
                  onChanged: (v) => m.onChanged(ref, v.round()),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value$suffix',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.primary,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAction(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    ActionModel m,
  ) {
    final dynamicSub = m.getDynamicSubtitle?.call(ref);
    final displaySub = dynamicSub ?? m.subtitle;

    return ListTile(
      leading: Icon(m.icon, color: theme.colorScheme.onSurfaceVariant),
      title: Text(m.title),
      subtitle: displaySub != null
          ? Text(
              displaySub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
      onTap: () => m.onTap(context, ref),
    );
  }
}
