import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_provider.dart';
import '../providers/ai_provider_providers.dart';
import '../utils/dialog_utils.dart';
import '../widgets/model_icon.dart';
import '../widgets/swipe_action_cell.dart';
import 'ai_provider_edit_page.dart';

class AiProviderListPage extends ConsumerStatefulWidget {
  const AiProviderListPage({super.key});

  @override
  ConsumerState<AiProviderListPage> createState() => _AiProviderListPageState();
}

class _AiProviderListPageState extends ConsumerState<AiProviderListPage> {
  bool _manageMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  Widget build(BuildContext context) {
    final providers = ref.watch(aiProviderListProvider);
    final pinned = providers.where((provider) => provider.pinned).toList();
    final others = providers.where((provider) => !provider.pinned).toList();

    return Scaffold(
      appBar: AppBar(
        leading: _manageMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: AiL10n.current.cancel,
                onPressed: _exitManageMode,
              )
            : null,
        title: Text(
          _manageMode
              ? AiL10n.current.selectedProviderCount(_selectedIds.length)
              : AiL10n.current.providersTitle,
        ),
        actions: _buildAppBarActions(context, providers),
      ),
      body: providers.isEmpty
          ? _buildEmpty(context)
          : _manageMode
              ? _ManageProviderList(
                  pinned: pinned,
                  others: others,
                  selectedIds: _selectedIds,
                  onToggleSelection: _toggleSelection,
                )
              : SwipeActionScope(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      if (pinned.isNotEmpty) ...[
                        _SectionLabel(text: AiL10n.current.pinnedProvidersSection),
                        _ProviderReorderSection(
                          providers: pinned,
                          pinned: true,
                          onReorder: _reorderProviders,
                          onEdit: (provider) =>
                              _navigateToEdit(context, provider),
                          onDelete: (provider) =>
                              _confirmDelete(context, provider),
                          onTogglePin: _togglePin,
                        ),
                        if (others.isNotEmpty) const SizedBox(height: 16),
                      ],
                      if (others.isNotEmpty) ...[
                        _SectionLabel(text: AiL10n.current.otherProvidersSection),
                        _ProviderReorderSection(
                          providers: others,
                          pinned: false,
                          onReorder: _reorderProviders,
                          onEdit: (provider) =>
                              _navigateToEdit(context, provider),
                          onDelete: (provider) =>
                              _confirmDelete(context, provider),
                          onTogglePin: _togglePin,
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  List<Widget> _buildAppBarActions(
    BuildContext context,
    List<AiProvider> providers,
  ) {
    if (_manageMode) {
      return [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: AiL10n.current.deleteSelectedProviders,
          onPressed: _selectedIds.isEmpty ? null : () => _confirmBatchDelete(context),
        ),
      ];
    }

    return [
      if (providers.isNotEmpty)
        IconButton(
          key: const ValueKey('provider_manage_button'),
          icon: const Icon(Icons.checklist_rounded),
          tooltip: AiL10n.current.manage,
          onPressed: _enterManageMode,
        ),
      IconButton(
        icon: const Icon(Icons.add),
        tooltip: AiL10n.current.addProvider,
        onPressed: () => _navigateToEdit(context),
      ),
    ];
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            AiL10n.current.noProviderConfigured,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AiL10n.current.addProviderHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _navigateToEdit(context),
            icon: const Icon(Icons.add),
            label: Text(AiL10n.current.addProvider),
          ),
        ],
      ),
    );
  }

  void _navigateToEdit(BuildContext context, [AiProvider? provider]) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AiProviderEditPage(provider: provider),
      ),
    );
  }

  void _enterManageMode() {
    setState(() {
      _manageMode = true;
      _selectedIds.clear();
    });
  }

  void _exitManageMode() {
    setState(() {
      _manageMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _togglePin(AiProvider provider) async {
    await ref.read(aiProviderListProvider.notifier).togglePin(provider.id);
  }

  Future<void> _reorderProviders(
    bool pinned,
    int oldIndex,
    int newIndex,
  ) async {
    final notifier = ref.read(aiProviderListProvider.notifier);
    if (pinned) {
      await notifier.reorderPinned(oldIndex, newIndex);
    } else {
      await notifier.reorderUnpinned(oldIndex, newIndex);
    }
  }

  Future<void> _confirmDelete(BuildContext context, AiProvider provider) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AiL10n.current.confirmDelete),
        content: Text(AiL10n.current.confirmDeleteProvider(provider.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AiL10n.current.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(AiL10n.current.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(aiProviderListProvider.notifier).removeProvider(provider.id);
    }
  }

  Future<void> _confirmBatchDelete(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AiL10n.current.confirmDelete),
        content: Text(
          AiL10n.current.confirmDeleteSelectedProviders(_selectedIds.length),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AiL10n.current.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(AiL10n.current.deleteSelectedProviders),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(aiProviderListProvider.notifier).removeProviders(_selectedIds);
      if (mounted) {
        _exitManageMode();
      }
    }
  }
}

class _ProviderReorderSection extends StatelessWidget {
  const _ProviderReorderSection({
    required this.providers,
    required this.pinned,
    required this.onReorder,
    required this.onEdit,
    required this.onDelete,
    required this.onTogglePin,
  });

  final List<AiProvider> providers;
  final bool pinned;
  final Future<void> Function(bool pinned, int oldIndex, int newIndex) onReorder;
  final ValueChanged<AiProvider> onEdit;
  final ValueChanged<AiProvider> onDelete;
  final ValueChanged<AiProvider> onTogglePin;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: providers.length,
      onReorderItem: (oldIndex, newIndex) async {
        await onReorder(pinned, oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final provider = providers[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey(provider.id),
          index: index,
          child: Padding(
            padding: EdgeInsets.only(bottom: index < providers.length - 1 ? 8 : 0),
            child: SwipeActionCell(
              key: ValueKey('swipe_${provider.id}'),
              enableLongPressMenu: false,
              trailingActions: [
                SwipeAction(
                  icon: Icons.edit_outlined,
                  color: Colors.blue,
                  label: AiL10n.current.edit,
                  onPressed: () => onEdit(provider),
                ),
                SwipeAction(
                  icon: Icons.delete_outline,
                  color: Colors.red,
                  label: AiL10n.current.delete,
                  onPressed: () => onDelete(provider),
                ),
              ],
              child: _ProviderCard(
                provider: provider,
                showSelection: false,
                onTap: () => onEdit(provider),
                onTogglePin: () => onTogglePin(provider),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ManageProviderList extends StatelessWidget {
  const _ManageProviderList({
    required this.pinned,
    required this.others,
    required this.selectedIds,
    required this.onToggleSelection,
  });

  final List<AiProvider> pinned;
  final List<AiProvider> others;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelection;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (pinned.isNotEmpty) ...[
          _SectionLabel(text: AiL10n.current.pinnedProvidersSection),
          ..._buildSectionItems(pinned),
          if (others.isNotEmpty) const SizedBox(height: 16),
        ],
        if (others.isNotEmpty) ...[
          _SectionLabel(text: AiL10n.current.otherProvidersSection),
          ..._buildSectionItems(others),
        ],
      ],
    );
  }

  List<Widget> _buildSectionItems(List<AiProvider> providers) {
    return [
      for (var index = 0; index < providers.length; index++)
        Padding(
          padding: EdgeInsets.only(bottom: index < providers.length - 1 ? 8 : 0),
          child: _ProviderCard(
            provider: providers[index],
            selected: selectedIds.contains(providers[index].id),
            showSelection: true,
            onTap: () => onToggleSelection(providers[index].id),
          ),
        ),
    ];
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.onTap,
    this.selected = false,
    this.showSelection = false,
    this.onTogglePin,
  });

  final AiProvider provider;
  final VoidCallback onTap;
  final bool selected;
  final bool showSelection;
  final VoidCallback? onTogglePin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabledCount = provider.models.where((model) => model.enabled).length;
    final totalCount = provider.models.length;

    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ModelIcon(
                providerName: provider.name,
                modelName: provider.name,
                size: 44,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      provider.name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            provider.type.label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          AiL10n.current.modelCount(enabledCount, totalCount),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (showSelection)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                )
              else ...[
                IconButton(
                  key: ValueKey('pin_${provider.id}'),
                  tooltip: provider.pinned
                      ? AiL10n.current.unpinProvider
                      : AiL10n.current.pinProvider,
                  onPressed: onTogglePin,
                  icon: Icon(
                    provider.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20,
                    color: provider.pinned
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.outline.withValues(alpha: 0.4),
                  size: 20,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
