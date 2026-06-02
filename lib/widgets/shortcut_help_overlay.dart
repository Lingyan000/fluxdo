import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/s.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../utils/dialog_utils.dart';
import 'shortcut/shortcut_ui.dart';

/// 显示快捷键帮助浮层，返回 Future 以便跟踪关闭时机
Future<void> showShortcutHelpOverlay(BuildContext context, WidgetRef ref) {
  final bindings = ref.read(shortcutProvider);

  return showAppDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    shortcutSurface: const ShortcutSurfaceConfig(
      id: ShortcutSurfaceIds.shortcutHelp,
      triggerAction: ShortcutAction.showShortcutHelp,
      repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
    ),
    builder: (context) => _ShortcutHelpDialog(bindings: bindings),
  );
}

class _ShortcutHelpDialog extends StatefulWidget {
  final List<ShortcutBinding> bindings;

  const _ShortcutHelpDialog({required this.bindings});

  @override
  State<_ShortcutHelpDialog> createState() => _ShortcutHelpDialogState();
}

class _ShortcutHelpDialogState extends State<_ShortcutHelpDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width * 0.88).clamp(360.0, 920.0).toDouble();
    final dialogHeight = (size.height * 0.84).clamp(420.0, 720.0).toDouble();
    final groups = _buildGroups(
      widget.bindings,
      l10n: l10n,
      query: _searchQuery,
    );

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      clipBehavior: Clip.antiAlias,
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Column(
            children: [
              _ShortcutDialogHeader(theme: theme, l10n: l10n),
              const SizedBox(height: 16),
              _ShortcutSearchField(
                controller: _searchController,
                value: _searchQuery,
                onChanged: (value) => setState(() => _searchQuery = value),
                onClear: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
              const SizedBox(height: 14),
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (groups.isEmpty) {
                      return _ShortcutEmptyState(
                        title: l10n.settings_searchEmpty,
                        query: _searchQuery,
                      );
                    }

                    final columnCount = constraints.maxWidth >= 760 ? 2 : 1;
                    final columns = _buildMasonryColumns(groups, columnCount);

                    return Scrollbar(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < columns.length; i++) ...[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    for (var j = 0; j < columns[i].length; j++) ...[
                                      if (j != 0) const SizedBox(height: 16),
                                      _ShortcutCategoryCard(
                                        title: shortcutCategoryLabel(
                                          columns[i][j].category,
                                          l10n,
                                        ),
                                        bindings: columns[i][j].bindings,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (i != columns.length - 1) const SizedBox(width: 16),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _ShortcutSearchField({
    required this.controller,
    required this.value,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: l10n.settings_searchHint,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: value.isEmpty
            ? null
            : IconButton(
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.92),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.65),
          ),
        ),
      ),
    );
  }
}

class _ShortcutDialogHeader extends StatelessWidget {
  final ThemeData theme;
  final AppLocalizations l10n;

  const _ShortcutDialogHeader({required this.theme, required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.settings_shortcuts,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.shortcuts_customizeHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
          style: IconButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(32, 32),
          ),
        ),
      ],
    );
  }
}

class _ShortcutEmptyState extends StatelessWidget {
  final String title;
  final String query;

  const _ShortcutEmptyState({required this.title, required this.query});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 34,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          if (query.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '“${query.trim()}”',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShortcutCategoryCard extends StatelessWidget {
  final String title;
  final List<ShortcutBinding> bindings;

  const _ShortcutCategoryCard({required this.title, required this.bindings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < bindings.length; i++) ...[
            _ShortcutRow(binding: bindings[i]),
            if (i != bindings.length - 1) ...[
              const SizedBox(height: 8),
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final ShortcutBinding binding;

  const _ShortcutRow({required this.binding});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, right: 8),
            child: Text(
              shortcutActionLabel(binding.action, l10n),
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.3,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Align(
            alignment: Alignment.topRight,
            child: ShortcutActivatorCaps(activator: binding.activator),
          ),
        ),
      ],
    );
  }
}

class _ShortcutGroup {
  const _ShortcutGroup({required this.category, required this.bindings});

  final ShortcutCategory category;
  final List<ShortcutBinding> bindings;
}

List<_ShortcutGroup> _buildGroups(
  List<ShortcutBinding> bindings, {
  required AppLocalizations l10n,
  required String query,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final groupedBindings = <ShortcutCategory, List<ShortcutBinding>>{
    for (final category in ShortcutCategory.values) category: <ShortcutBinding>[],
  };

  for (final binding in bindings) {
    groupedBindings.putIfAbsent(binding.category, () => []).add(binding);
  }

  return [
    for (final category in ShortcutCategory.values)
      if (_filterBindingsForCategory(
        groupedBindings[category] ?? const [],
        category: category,
        l10n: l10n,
        query: normalizedQuery,
      ).isNotEmpty)
        _ShortcutGroup(
          category: category,
          bindings: List<ShortcutBinding>.unmodifiable(
            _filterBindingsForCategory(
              groupedBindings[category] ?? const [],
              category: category,
              l10n: l10n,
              query: normalizedQuery,
            ),
          ),
        ),
  ];
}

List<ShortcutBinding> _filterBindingsForCategory(
  List<ShortcutBinding> bindings, {
  required ShortcutCategory category,
  required AppLocalizations l10n,
  required String query,
}) {
  if (query.isEmpty) return bindings;

  final categoryLabel = shortcutCategoryLabel(category, l10n).toLowerCase();
  if (categoryLabel.contains(query)) {
    return bindings;
  }

  return bindings.where((binding) {
    final actionLabel = shortcutActionLabel(binding.action, l10n).toLowerCase();
    final keyLabel = ShortcutBinding.formatActivator(binding.activator)
        .toLowerCase();
    final keyParts = ShortcutBinding.formatActivatorParts(binding.activator)
        .join(' ')
        .toLowerCase();
    return actionLabel.contains(query) ||
        keyLabel.contains(query) ||
        keyParts.contains(query);
  }).toList();
}

List<List<_ShortcutGroup>> _buildMasonryColumns(
  List<_ShortcutGroup> groups,
  int columnCount,
) {
  final columns = List.generate(columnCount, (_) => <_ShortcutGroup>[]);
  final estimatedHeights = List<double>.filled(columnCount, 0);

  for (final group in groups) {
    var targetColumn = 0;
    for (var i = 1; i < columnCount; i++) {
      if (estimatedHeights[i] < estimatedHeights[targetColumn]) {
        targetColumn = i;
      }
    }

    columns[targetColumn].add(group);
    estimatedHeights[targetColumn] += 68 + group.bindings.length * 54;
  }

  return columns;
}
