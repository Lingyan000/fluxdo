import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';

/// 并发与限流设置卡片
///
/// 默认仅展示「省心 / 均衡 / 极速 / 自定义」四档预设,选自定义才展开 slider。
/// 卡片右上角提供「恢复默认」一键复位。
class RateLimitCard extends ConsumerStatefulWidget {
  const RateLimitCard({super.key});

  @override
  ConsumerState<RateLimitCard> createState() => _RateLimitCardState();
}

class _RateLimitCardState extends ConsumerState<RateLimitCard> {
  bool _advancedExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = ref.watch(preferencesProvider);
    final notifier = ref.read(preferencesProvider.notifier);
    final l10n = context.l10n;

    final current = _RateLimitTriple(
      prefs.maxConcurrent,
      prefs.maxPerWindow,
      prefs.windowSeconds,
    );
    final preset = _presetOf(current);
    final isCustom = preset == _RateLimitPreset.custom;

    // 自定义模式下保持展开;反之尊重用户折叠状态。
    final advancedOpen = isCustom || _advancedExpanded;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            title: l10n.networkSettings_rateLimitTitle,
            subtitle: l10n.networkSettings_rateLimitSubtitle,
            onReset: _isDefault(current)
                ? null
                : () => _confirmReset(context, notifier),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PresetSelector(
                  current: preset,
                  onSelect: (p) {
                    if (p == _RateLimitPreset.custom) {
                      setState(() => _advancedExpanded = true);
                      return;
                    }
                    final t = _presetValues[p]!;
                    notifier.setMaxConcurrent(t.maxConcurrent);
                    notifier.setMaxPerWindow(t.maxPerWindow);
                    notifier.setWindowSeconds(t.windowSeconds);
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.networkSettings_rateLimitSummary(
                    prefs.windowSeconds,
                    prefs.maxPerWindow,
                    prefs.maxConcurrent,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
          InkWell(
            onTap: isCustom
                ? null
                : () => setState(() => _advancedExpanded = !_advancedExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Symbols.tune_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.networkSettings_rateLimitAdvanced,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  AnimatedRotation(
                    turns: advancedOpen ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Symbols.expand_more_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: advancedOpen
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  _SliderTile(
                    icon: Symbols.swap_horiz_rounded,
                    label: l10n.networkSettings_maxConcurrent,
                    helper: l10n.networkSettings_maxConcurrentDesc,
                    value: prefs.maxConcurrent,
                    min: 1,
                    max: 10,
                    onChanged: notifier.setMaxConcurrent,
                  ),
                  const Divider(height: 1, indent: 56),
                  _SliderTile(
                    icon: Symbols.speed_rounded,
                    label: l10n.networkSettings_maxPerWindow,
                    helper: l10n.networkSettings_maxPerWindowDesc,
                    value: prefs.maxPerWindow,
                    min: 2,
                    max: 30,
                    onChanged: notifier.setMaxPerWindow,
                  ),
                  const Divider(height: 1, indent: 56),
                  _SliderTile(
                    icon: Symbols.timer_rounded,
                    label: l10n.networkSettings_windowSeconds,
                    helper: l10n.networkSettings_windowSecondsDesc,
                    value: prefs.windowSeconds,
                    min: 1,
                    max: 10,
                    suffix: l10n.networkSettings_windowSecondsSuffix,
                    onChanged: notifier.setWindowSeconds,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    PreferencesNotifier notifier,
  ) async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.networkSettings_rateLimitReset),
        content: Text(
          l10n.networkSettings_rateLimitSummary(
            _defaults.windowSeconds,
            _defaults.maxPerWindow,
            _defaults.maxConcurrent,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await notifier.setMaxConcurrent(_defaults.maxConcurrent);
    await notifier.setMaxPerWindow(_defaults.maxPerWindow);
    await notifier.setWindowSeconds(_defaults.windowSeconds);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.networkSettings_rateLimitResetDone)),
    );
  }

  bool _isDefault(_RateLimitTriple t) => t == _defaults;

  _RateLimitPreset _presetOf(_RateLimitTriple t) {
    for (final entry in _presetValues.entries) {
      if (entry.value == t) return entry.key;
    }
    return _RateLimitPreset.custom;
  }
}

/// 卡片头部:标题 + 副标题 + 重置按钮(仅非默认值时显示)。
class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onReset;

  const _Header({
    required this.title,
    required this.subtitle,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.l10n.networkSettings_rateLimitReset,
            onPressed: onReset,
            icon: const Icon(Symbols.restore_rounded, size: 20),
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _PresetSelector extends StatelessWidget {
  final _RateLimitPreset current;
  final ValueChanged<_RateLimitPreset> onSelect;

  const _PresetSelector({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final items = <(_RateLimitPreset, String, String)>[
      (
        _RateLimitPreset.gentle,
        l10n.networkSettings_rateLimitPresetGentle,
        l10n.networkSettings_rateLimitPresetGentleDesc,
      ),
      (
        _RateLimitPreset.balanced,
        l10n.networkSettings_rateLimitPresetBalanced,
        l10n.networkSettings_rateLimitPresetBalancedDesc,
      ),
      (
        _RateLimitPreset.turbo,
        l10n.networkSettings_rateLimitPresetTurbo,
        l10n.networkSettings_rateLimitPresetTurboDesc,
      ),
      (
        _RateLimitPreset.custom,
        l10n.networkSettings_rateLimitPresetCustom,
        l10n.networkSettings_rateLimitPresetCustomDesc,
      ),
    ];

    final selected = items.firstWhere((e) => e.$1 == current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              ChoiceChip(
                label: Text(item.$2),
                selected: item.$1 == current,
                onSelected: (s) {
                  if (s) onSelect(item.$1);
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          selected.$3,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SliderTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? helper;
  final int value;
  final int min;
  final int max;
  final String? suffix;
  final ValueChanged<int> onChanged;

  const _SliderTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.helper,
    this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(label, style: theme.textTheme.bodyMedium),
                ),
                if (helper != null)
                  Text(
                    helper!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                // 滑块样式走全局主题(M3E 开 = year2023 新样式)
                Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  divisions: max - min,
                  label: suffix != null ? '$value $suffix' : '$value',
                  onChanged: (v) => onChanged(v.round()),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 40,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                suffix != null ? '$value$suffix' : '$value',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.primary,
                ),
                textAlign: TextAlign.end,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _RateLimitPreset { gentle, balanced, turbo, custom }

class _RateLimitTriple {
  final int maxConcurrent;
  final int maxPerWindow;
  final int windowSeconds;
  const _RateLimitTriple(this.maxConcurrent, this.maxPerWindow, this.windowSeconds);

  @override
  bool operator ==(Object other) =>
      other is _RateLimitTriple &&
      other.maxConcurrent == maxConcurrent &&
      other.maxPerWindow == maxPerWindow &&
      other.windowSeconds == windowSeconds;

  @override
  int get hashCode => Object.hash(maxConcurrent, maxPerWindow, windowSeconds);
}

// 与 preferences_provider.dart 默认值保持一致(maxConcurrent=3 / 6 / 3)
const _defaults = _RateLimitTriple(3, 6, 3);

const _presetValues = <_RateLimitPreset, _RateLimitTriple>{
  _RateLimitPreset.gentle: _RateLimitTriple(2, 6, 5),
  _RateLimitPreset.balanced: _defaults,
  _RateLimitPreset.turbo: _RateLimitTriple(6, 15, 3),
};
