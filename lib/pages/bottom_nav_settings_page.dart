import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../navigation/nav_action_bus.dart';
import '../navigation/nav_entry.dart';
import '../navigation/nav_entry_registry.dart';
import '../providers/discourse_providers.dart';
import '../providers/preferences_provider.dart';
import '../services/toast_service.dart';
import '../settings/definitions/bottom_nav_defs.dart';
import '../settings/settings_model.dart';
import '../settings/settings_renderer.dart';
import '../utils/dialog_utils.dart';

/// 底栏设置页
///
/// 布局：
/// - 顶部：真实底栏样式的预览，支持水平拖动排序（首页锁定第 0 位）
/// - 中部：可添加的候选池（点 + 加入）
/// - 底部：手势分组（复用 [SettingsRenderer] 渲染 bottom_nav_defs 的 ActionModel）
///
/// 约束：2 ≤ 已启用数量 ≤ 5；locked entry（home、profile）不可移除。
class BottomNavSettingsPage extends ConsumerStatefulWidget {
  final String? highlightId;

  const BottomNavSettingsPage({super.key, this.highlightId});

  @override
  ConsumerState<BottomNavSettingsPage> createState() =>
      _BottomNavSettingsPageState();
}

class _BottomNavSettingsPageState
    extends ConsumerState<BottomNavSettingsPage> {
  static const int _minCount = 2;
  static const int _maxCount = 5;

  late List<String> _enabledIds;

  @override
  void initState() {
    super.initState();
    _enabledIds = List<String>.from(
      ref.read(preferencesProvider).bottomNavIds,
    );
    _sanitize();
  }

  /// 校验 + 首页锁 0 位
  void _sanitize() {
    final all = NavEntryRegistry.buildAll();
    final byId = {for (final e in all) e.id: e};
    final locked = NavEntryRegistry.lockedIds();

    final cleaned = <String>[];
    final seen = <String>{};

    // 首页永远第一位
    const homeId = NavEntryIds.home;
    if (byId.containsKey(homeId)) {
      cleaned.add(homeId);
      seen.add(homeId);
    }

    for (final id in _enabledIds) {
      if (id == homeId) continue;
      if (!byId.containsKey(id)) continue;
      if (seen.contains(id)) continue;
      cleaned.add(id);
      seen.add(id);
    }

    // 补 locked（profile 等）
    for (final id in locked) {
      if (seen.contains(id)) continue;
      cleaned.add(id);
      seen.add(id);
    }

    _enabledIds = cleaned;
  }

  Future<void> _persist() async {
    await ref
        .read(preferencesProvider.notifier)
        .setBottomNavIds(List<String>.from(_enabledIds));
  }

  void _onReorder(int oldIndex, int newIndex) {
    // 首页锁 0 位
    if (_enabledIds[oldIndex] == NavEntryIds.home) return;
    if (newIndex == 0) newIndex = 1;
    setState(() {
      final item = _enabledIds.removeAt(oldIndex);
      _enabledIds.insert(newIndex, item);
    });
    _persist();
  }

  Future<void> _addEntry(NavEntry entry) async {
    if (_enabledIds.length >= _maxCount) {
      ToastService.showInfo(
        S.current.bottomNav_editorMaxReached(_maxCount),
      );
      return;
    }
    setState(() => _enabledIds.add(entry.id));
    await _persist();
  }

  Future<void> _removeEntry(NavEntry entry) async {
    if (entry.locked) return;
    if (_enabledIds.length <= _minCount) {
      ToastService.showInfo(
        S.current.bottomNav_editorMinReached(_minCount),
      );
      return;
    }
    setState(() => _enabledIds.remove(entry.id));
    await _persist();
  }

  Future<void> _restoreDefault() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.bottomNav_editorRestoreDefault),
        content: Text(ctx.l10n.bottomNav_editorRestoreDefaultConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.common_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _enabledIds = NavEntryRegistry.defaultBottomNavIds();
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).value;

    final all = NavEntryRegistry.buildAll();
    final byId = {for (final e in all) e.id: e};
    final enabled =
        _enabledIds.map((id) => byId[id]).whereType<NavEntry>().toList();
    final available =
        all.where((e) => !_enabledIds.contains(e.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.bottomNav_title),
        actions: [
          TextButton(
            onPressed: _restoreDefault,
            child: Text(l10n.bottomNav_editorRestoreDefault),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _SectionHeader(
            title: l10n.bottomNav_editorTitle,
            subtitle: l10n.bottomNav_editorPreviewHint,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _PreviewBar(
              entries: enabled,
              minCount: _minCount,
              onReorder: _onReorder,
              onRemove: _removeEntry,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Text(
              l10n.bottomNav_editorEnabledHint(
                enabled.length,
                _minCount,
                _maxCount,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 20),
          _SectionHeader(
            title: l10n.bottomNav_editorAvailable,
            subtitle:
                available.isEmpty ? l10n.bottomNav_editorEmptyAvailable : null,
          ),
          if (available.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
              child: Text(
                l10n.bottomNav_editorEmptyAvailable,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Column(
                  children: [
                    for (int i = 0; i < available.length; i++) ...[
                      _AvailableTile(
                        entry: available[i],
                        canAdd: NavEntryRegistry.isAvailable(
                              available[i],
                              user,
                            ) &&
                            enabled.length < _maxCount,
                        needsLogin:
                            available[i].requiresLogin && user == null,
                        onAdd: () => _addEntry(available[i]),
                      ),
                      if (i < available.length - 1)
                        Divider(
                          height: 1,
                          indent: 56,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.3),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          for (final group in buildBottomNavGroups(context))
            _GestureGroup(group: group),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.primary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
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

/// 水平 ReorderableListView 模拟底栏样式
class _PreviewBar extends StatelessWidget {
  const _PreviewBar({
    required this.entries,
    required this.minCount,
    required this.onReorder,
    required this.onRemove,
  });

  final List<NavEntry> entries;
  final int minCount;
  final void Function(int, int) onReorder;
  final void Function(NavEntry) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 108,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        buildDefaultDragHandles: false,
        onReorderItem: onReorder,
        onReorderStart: (_) => HapticFeedback.mediumImpact(),
        onReorderEnd: (_) => HapticFeedback.selectionClick(),
        itemCount: entries.length,
        proxyDecorator: (child, index, anim) {
          return AnimatedBuilder(
            animation: anim,
            builder: (ctx, c) {
              final lift = Curves.easeOut.transform(anim.value);
              return Transform.scale(
                scale: 1.0 + 0.08 * lift,
                child: Material(
                  color: Colors.transparent,
                  elevation: 12 * lift,
                  shadowColor: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                  child: c,
                ),
              );
            },
            child: child,
          );
        },
        itemBuilder: (ctx, i) {
          final e = entries[i];
          final canRemove = !e.locked && entries.length > minCount;
          return _PreviewItem(
            key: ValueKey('preview-${e.id}'),
            entry: e,
            index: i,
            canDrag: !e.locked,
            canRemove: canRemove,
            onRemove: () => onRemove(e),
          );
        },
      ),
    );
  }
}

class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required super.key,
    required this.entry,
    required this.index,
    required this.canDrag,
    required this.canRemove,
    required this.onRemove,
  });

  final NavEntry entry;
  final int index;
  final bool canDrag;
  final bool canRemove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final core = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        width: 84,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 64,
                    height: 36,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      entry.selectedIconData,
                      size: 22,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  if (canRemove)
                    Positioned(
                      top: -6,
                      right: 0,
                      child: InkResponse(
                        onTap: onRemove,
                        radius: 16,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.surface,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            size: 12,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    )
                  else if (entry.locked)
                    Positioned(
                      top: -4,
                      right: 0,
                      child: Icon(
                        Icons.lock_rounded,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.55),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                entry.label(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );

    if (canDrag) {
      // Delayed 避免水平滑动误触；长按 ~500ms 才进入拖动
      return ReorderableDelayedDragStartListener(
        key: key,
        index: index,
        child: core,
      );
    }
    // 首页等 locked 项：不包拖动监听，但仍需要有 Key
    return KeyedSubtree(key: key, child: core);
  }
}

class _AvailableTile extends StatelessWidget {
  const _AvailableTile({
    required this.entry,
    required this.canAdd,
    required this.needsLogin,
    required this.onAdd,
  });

  final NavEntry entry;
  final bool canAdd;
  final bool needsLogin;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(entry.iconData),
      title: Text(entry.label(context)),
      subtitle: needsLogin
          ? Text(
              context.l10n.bottomNav_editorRequiresLogin,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: IconButton(
        icon: Icon(
          Icons.add_circle_outline_rounded,
          color: canAdd
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        onPressed: canAdd ? onAdd : null,
      ),
      onTap: canAdd ? onAdd : null,
    );
  }
}

/// 手势分组：读取 [buildBottomNavGroups] 的 SettingsGroup，
/// 用 SettingsRenderer 渲染 items
class _GestureGroup extends StatelessWidget {
  const _GestureGroup({required this.group});
  final SettingsGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Row(
            children: [
              Icon(group.icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                group.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < group.items.length; i++) ...[
                  SettingsRenderer(model: group.items[i]),
                  if (i < group.items.length - 1)
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant
                          .withValues(alpha: 0.3),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
