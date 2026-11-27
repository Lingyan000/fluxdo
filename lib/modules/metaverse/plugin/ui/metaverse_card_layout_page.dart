import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../services/toast_service.dart';
import '../providers/metaverse_plugin_providers.dart';

class MetaverseCardLayoutPage extends ConsumerStatefulWidget {
  const MetaverseCardLayoutPage({super.key});
  @override
  ConsumerState<MetaverseCardLayoutPage> createState() => _CardLayoutState();
}

class _CardLayoutState extends ConsumerState<MetaverseCardLayoutPage> {
  bool busy = false;
  Future<void> save(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ToastService.showError(context.l10n.metaverse_permissionSaveFailed);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = ref.watch(metaverseCardLayoutProvider);
    final installed = {
      for (final p in ref.watch(metaversePluginsProvider)) p.id: p,
    };
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.metaverse_arrangeCards)),
      body: layout.isEmpty
          ? AppEmptyState(
              icon: const Icon(Symbols.extension_rounded),
              title: context.l10n.metaverse_marketEmpty,
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(16),
              buildDefaultDragHandles: false,
              header: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(context.l10n.metaverse_cardLayoutNote),
              ),
              itemCount: layout.length,
              onReorderItem: (oldIndex, newIndex) => save(
                () => ref
                    .read(metaverseCardLayoutProvider.notifier)
                    .reorder(oldIndex, newIndex),
              ),
              itemBuilder: (context, index) {
                final item = layout[index], plugin = installed[item.id]!;
                return SegmentedCardItem(
                  key: ValueKey(item.id),
                  index: index,
                  count: layout.length,
                  color: PageBackgroundScope.contentColor(
                    context,
                    Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: M3eSwitchListTile(
                          title: Text(
                            plugin.manifest.localizedName(
                              context.l10n.localeName,
                            ),
                          ),
                          value: item.visible,
                          onChanged: busy
                              ? null
                              : (value) => save(
                                  () => ref
                                      .read(
                                        metaverseCardLayoutProvider.notifier,
                                      )
                                      .setVisible(item.id, value),
                                ),
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        enabled: !busy,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Icon(
                            Symbols.drag_handle_rounded,
                            semanticLabel: context.l10n.metaverse_arrangeCards,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
