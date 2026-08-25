import 'package:flutter/gestures.dart'
    show
        DelayedMultiDragGestureRecognizer,
        ImmediateMultiDragGestureRecognizer,
        PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:app_icons/app_icons.dart';
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
import '../utils/responsive.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 底栏设置页
///
/// 布局：
/// - 顶部：真实底栏样式的预览，支持水平拖动排序（首页锁定第 0 位）
/// - 中部：可添加的候选池（点 + 加入）
/// - 底部：手势分组（复用 [SettingsRenderer] 渲染 bottom_nav_defs 的 ActionModel）
///
/// 约束：2 ≤ 已启用数量 ≤ 上限；locked entry（home、profile）不可移除。
///
/// 上限按屏幕宽度自适应,不再是写死的 5——手机底栏是横向 `NavigationBar`,
/// 塞太多图标会被越挤越窄;平板/桌面走的是竖排 `NavigationRail`,横向
/// 空间宽裕,没必要卡在手机的上限,直接放开到全部已注册入口数。
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

  /// 搜索跳转定位:手势分组条目的锚点与高亮(与 SettingsGroupPage 同机制;
  /// 本页布局手写,不走 SettingsGroupPage,只能自备一份)
  final Map<String, GlobalKey> _itemKeys = {};
  String? _highlightedId;

  /// 手机横向底栏容易被挤,上限保守;平板竖排 rail 空间宽裕给到 7;
  /// 桌面宽屏干脆不设人为上限,放开到当前全部已注册入口数。
  int get _maxCount {
    switch (Responsive.getDeviceType(context)) {
      case DeviceType.mobile:
        return 5;
      case DeviceType.tablet:
        return 7;
      case DeviceType.desktop:
        return NavEntryRegistry.buildAll().length;
    }
  }

  late List<String> _enabledIds;

  @override
  void initState() {
    super.initState();
    _enabledIds = List<String>.from(
      ref.read(preferencesProvider).bottomNavIds,
    );
    _sanitize();
    if (widget.highlightId != null) {
      _highlightedId = widget.highlightId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight());
    }
  }

  void _scrollToHighlight() {
    final key = _itemKeys[_highlightedId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.3,
      );
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightedId = null);
    });
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
        // 搜索定位目标(手势分组)在页尾,懒加载不挂载会导致 ensureVisible
        // 拿不到 context;带 highlightId 时强制全量布局(与 SettingsGroupPage 同策)
        scrollCacheExtent: widget.highlightId != null
            ? const ScrollCacheExtent.pixels(double.maxFinite)
            : null,
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
              child: SegmentedCardGroup(
                children: [
                  for (final entry in available)
                    _AvailableTile(
                      entry: entry,
                      canAdd: NavEntryRegistry.isAvailable(
                            entry,
                            user,
                          ) &&
                          enabled.length < _maxCount,
                      needsLogin: entry.requiresLogin && user == null,
                      onAdd: () => _addEntry(entry),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          for (final group in buildBottomNavGroups(context))
            _GestureGroup(
              group: group,
              itemKeys: _itemKeys,
              highlightedId: _highlightedId,
            ),
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
            canDrag: e.id != NavEntryIds.home,
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
                            Symbols.close_rounded,
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
                        Symbols.lock_rounded,
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
      // 按指针类型分流手感（见 _PointerAwareDragStartListener）；
      // 只有首页固定在第一位。
      return _PointerAwareDragStartListener(
        key: key,
        index: index,
        child: core,
      );
    }
    // 首页固定项：不包拖动监听，但仍需要有 Key
    return KeyedSubtree(key: key, child: core);
  }
}

/// 按指针类型分流的拖拽监听：鼠标/触控板按下即拖（桌面手感），触屏
/// 长按进入拖拽。触屏若也即按即拖，手指落在预览条上就无法滚动页面
/// （拖拽识别器会立刻抢占滚动手势）。
class _PointerAwareDragStartListener extends StatelessWidget {
  const _PointerAwareDragStartListener({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        final list = SliverReorderableList.maybeOf(context);
        if (list == null) return;
        final recognizer = switch (event.kind) {
          PointerDeviceKind.mouse ||
          PointerDeviceKind.trackpad =>
            ImmediateMultiDragGestureRecognizer(debugOwner: this),
          _ => DelayedMultiDragGestureRecognizer(debugOwner: this),
        };
        list.startItemDragReorder(
          index: index,
          event: event,
          recognizer: recognizer
            ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context),
        );
      },
      child: child,
    );
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
          Symbols.add_circle_rounded,
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

/// 设置分组：读取 [buildBottomNavGroups] 的 SettingsGroup，
/// 用 SettingsRenderer 渲染 items（先按可见性过滤，避免隐藏项零高占位
/// 顶掉分段卡片组尾的大圆角）
class _GestureGroup extends ConsumerWidget {
  const _GestureGroup({
    required this.group,
    required this.itemKeys,
    required this.highlightedId,
  });
  final SettingsGroup group;
  final Map<String, GlobalKey> itemKeys;
  final String? highlightedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 隐藏项（如依赖前置开关的条目）不进卡片组，否则零高占位会顶掉
    // 组尾的大圆角（SegmentedCardGroup 按位置分配圆角）
    final visibleItems =
        group.items.where((item) => item.isVisible(ref)).toList();
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
          child: SegmentedCardGroup(
            children: [
              for (final item in visibleItems)
                AnimatedContainer(
                  key: itemKeys.putIfAbsent(item.id, () => GlobalKey()),
                  duration: const Duration(milliseconds: 500),
                  color: highlightedId == item.id
                      ? theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.4,
                        )
                      : Colors.transparent,
                  child: SettingsRenderer(model: item),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
