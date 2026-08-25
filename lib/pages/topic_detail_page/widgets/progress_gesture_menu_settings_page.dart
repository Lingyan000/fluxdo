import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import 'progress_gesture_action_meta.dart';

/// 长按菜单功能设置页：在半圆预览区里直接完成全部操作（拖动排序、拖到中央
/// 删除区移除），下方「可添加」列表点 + 添加。
class ProgressGestureMenuSettingsPage extends ConsumerStatefulWidget {
  const ProgressGestureMenuSettingsPage({super.key});

  @override
  ConsumerState<ProgressGestureMenuSettingsPage> createState() =>
      _ProgressGestureMenuSettingsPageState();
}

class _ProgressGestureMenuSettingsPageState
    extends ConsumerState<ProgressGestureMenuSettingsPage> {
  late List<ProgressGestureAction> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List<ProgressGestureAction>.from(
      ref.read(preferencesProvider).progressGestureMenuActions,
    );
  }

  void _commit() {
    ref
        .read(preferencesProvider.notifier)
        .setProgressGestureMenuActions(_selected);
  }

  void _add(ProgressGestureAction action) {
    if (_selected.contains(action)) return;
    if (_selected.length >= kProgressGestureMenuMax) return;
    setState(() => _selected.add(action));
    _commit();
  }

  void _remove(int index) {
    if (index < 0 || index >= _selected.length) return;
    setState(() => _selected.removeAt(index));
    _commit();
  }

  void _reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _selected.length) return;
    if (oldIndex == newIndex) return;
    setState(() {
      final item = _selected.removeAt(oldIndex);
      final clamped = newIndex.clamp(0, _selected.length);
      _selected.insert(clamped, item);
    });
    _commit();
  }

  Future<void> _resetDefault() async {
    await ref
        .read(preferencesProvider.notifier)
        .resetProgressGestureMenuActions();
    if (!mounted) return;
    setState(() {
      _selected = List<ProgressGestureAction>.from(
        ref.read(preferencesProvider).progressGestureMenuActions,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final longPressEnabled = ref.watch(
      preferencesProvider.select((p) => p.progressGestureLongPressEnabled),
    );
    // 长按菜单候选不包含「无」（none 仅对滑动方向有意义）
    final available = ProgressGestureAction.values
        .where((a) => a != ProgressGestureAction.none && !_selected.contains(a))
        .toList();
    final atLimit = _selected.length >= kProgressGestureMenuMax;
    final canEdit = longPressEnabled;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.progressGesture_longPressMenu),
        actions: [
          TextButton(
            onPressed: canEdit ? _resetDefault : null,
            child: Text(l10n.progressGesture_resetDefault),
          ),
        ],
      ),
      body: ListView(
        children: [
          // 启用开关
          SwitchListTile(
            value: longPressEnabled,
            title: Text(l10n.progressGesture_longPressEnable),
            subtitle: Text(l10n.progressGesture_longPressEnableDesc),
            secondary: Icon(
              Symbols.fingerprint_rounded,
              color: theme.colorScheme.primary,
            ),
            onChanged: (v) => ref
                .read(preferencesProvider.notifier)
                .setProgressGestureLongPressEnabled(v),
          ),
          const Divider(height: 1),
          // 预览 + 操作区（禁用时整体置灰）
          Opacity(
            opacity: canEdit ? 1.0 : 0.4,
            child: IgnorePointer(
              ignoring: !canEdit,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: _PreviewArea(
                      items: _selected,
                      onReorder: _reorder,
                      onRemove: _remove,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: Text(
                      _selected.isEmpty
                          ? l10n.progressGesture_emptySelection
                          : '${_selected.length}/$kProgressGestureMenuMax · '
                                '${l10n.progressGesture_longPressReorderHint}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        l10n.progressGesture_sectionAvailable,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (available.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 24,
                      ),
                      child: Center(
                        child: Text(
                          l10n.progressGesture_menuCountFull,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final action in available)
                      _AvailableTile(
                        action: action,
                        enabled: canEdit && !atLimit,
                        onTap: () => _add(action),
                      ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================== 预览区 ==============================

class _PreviewArea extends StatefulWidget {
  const _PreviewArea({
    required this.items,
    required this.onReorder,
    required this.onRemove,
  });

  final List<ProgressGestureAction> items;
  final void Function(int oldIndex, int newIndex) onReorder;
  final void Function(int index) onRemove;

  @override
  State<_PreviewArea> createState() => _PreviewAreaState();
}

class _PreviewAreaState extends State<_PreviewArea> {
  int? _draggingIndex;
  int? _hoverSlot; // 当前手指悬停的目标 slot；null 表示无有效悬停
  bool _hoverDelete = false; // 手指悬停在中央删除区

  double _radiusForCount(int count) {
    if (count <= 4) return 92;
    if (count <= 6) return 108;
    return 128;
  }

  Offset _itemPosition(int index, int n, Offset center, double radius) {
    final double angle;
    if (n == 1) {
      angle = -math.pi / 2;
    } else {
      final step = math.pi / (n - 1);
      angle = -math.pi + index * step;
    }
    return Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
  }

  /// 计算项在 *预览状态* 下应该出现在哪个 slot。
  /// 拖动时，其他项让出 _hoverSlot 的位置；被拖项站到 _hoverSlot。
  int _previewSlotFor(int actualIndex, int n) {
    if (_draggingIndex == null || _hoverSlot == null || _hoverDelete) {
      return actualIndex;
    }
    if (actualIndex == _draggingIndex) return _hoverSlot!;
    final logical = actualIndex < _draggingIndex!
        ? actualIndex
        : actualIndex - 1;
    final hover = _hoverSlot!.clamp(0, n - 1);
    return logical < hover ? logical : logical + 1;
  }

  void _resetDragState() {
    if (_draggingIndex == null &&
        _hoverSlot == null &&
        !_hoverDelete) {
      return;
    }
    setState(() {
      _draggingIndex = null;
      _hoverSlot = null;
      _hoverDelete = false;
    });
  }

  void _handleHoverMove({
    required Offset globalPos,
    required RenderBox box,
    required Offset pillCenter,
    required Rect pillRect,
    required int n,
  }) {
    final localPos = box.globalToLocal(globalPos);

    // 删除区命中
    if (pillRect.inflate(12).contains(localPos)) {
      if (!_hoverDelete || _hoverSlot != null) {
        setState(() {
          _hoverDelete = true;
          _hoverSlot = null;
        });
      }
      return;
    }

    // slot 命中：上半圆按角度映射
    final dx = localPos.dx - pillCenter.dx;
    final dy = localPos.dy - pillCenter.dy;
    int? slot;
    if (dy < -8) {
      final angle = math.atan2(dy, dx);
      if (n <= 1) {
        slot = 0;
      } else {
        final step = math.pi / (n - 1);
        slot = ((angle + math.pi) / step).round().clamp(0, n - 1);
      }
    }

    if (_hoverSlot != slot || _hoverDelete) {
      setState(() {
        _hoverSlot = slot;
        _hoverDelete = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = widget.items.length;
    final radius = n == 0 ? 92.0 : _radiusForCount(n);
    final height = radius + 32 + 40 + 16; // radius + item 半径 + pill + 下边距

    if (n == 0) {
      return _EmptyPreview(height: height);
    }

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final pillCenter = Offset(width / 2, height - 36);
          final pillRect = Rect.fromCenter(
            center: pillCenter,
            width: 120,
            height: 40,
          );

          return DragTarget<int>(
            onWillAcceptWithDetails: (_) => true,
            onMove: (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              _handleHoverMove(
                globalPos: details.offset,
                box: box,
                pillCenter: pillCenter,
                pillRect: pillRect,
                n: n,
              );
            },
            onLeave: (_) {
              if (_hoverSlot != null || _hoverDelete) {
                setState(() {
                  _hoverSlot = null;
                  _hoverDelete = false;
                });
              }
            },
            onAcceptWithDetails: (details) {
              if (_hoverDelete) {
                widget.onRemove(details.data);
              } else if (_hoverSlot != null) {
                widget.onReorder(details.data, _hoverSlot!);
              }
              _resetDragState();
            },
            builder: (context, candidate, rejected) {
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // 半圆 items（每个用 AnimatedPositioned 让 preview 重排平滑）
                  for (int i = 0; i < n; i++)
                    _buildSlotItem(i, n, pillCenter, radius, theme),
                  // 中间：拖动时是删除区，闲置时是 pill 占位
                  Positioned.fromRect(
                    rect: pillRect,
                    child: _draggingIndex == null
                        ? _buildIdlePill(context, theme)
                        : _buildDeleteZone(
                            context,
                            theme,
                            active: _hoverDelete,
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSlotItem(
    int actualIndex,
    int n,
    Offset pillCenter,
    double radius,
    ThemeData theme,
  ) {
    final slot = _previewSlotFor(actualIndex, n);
    final pos = _itemPosition(slot, n, pillCenter, radius);
    const itemSize = 48.0;
    final action = widget.items[actualIndex];
    return AnimatedPositioned(
      key: ValueKey('item_$actualIndex'),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: pos.dx - itemSize / 2,
      top: pos.dy - itemSize / 2,
      width: itemSize,
      height: itemSize,
      child: LongPressDraggable<int>(
        data: actualIndex,
        delay: const Duration(milliseconds: 200),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _buildItemChip(context, action, theme, dragging: true),
        childWhenDragging: _buildPlaceholder(theme),
        onDragStarted: () => setState(() => _draggingIndex = actualIndex),
        onDragCompleted: _resetDragState,
        onDraggableCanceled: (_, _) => _resetDragState(),
        onDragEnd: (_) => _resetDragState(),
        child: _buildItemChip(context, action, theme),
      ),
    );
  }

  Widget _buildItemChip(
    BuildContext context,
    ProgressGestureAction action,
    ThemeData theme, {
    bool dragging = false,
  }) {
    final meta = progressGestureActionMeta(context, action);
    return Material(
      color: dragging
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      elevation: dragging ? 10 : 2,
      shadowColor: dragging
          ? theme.colorScheme.primary.withValues(alpha: 0.5)
          : Colors.black26,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(
          meta.icon,
          size: 22,
          color: dragging
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildPlaceholder(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
    );
  }

  Widget _buildIdlePill(BuildContext context, ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      shape: const StadiumBorder(),
      elevation: 2,
      shadowColor: Colors.black26,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${widget.items.length}',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                '/',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  ),
                  fontSize: 13,
                ),
              ),
            ),
            Text(
              '$kProgressGestureMenuMax',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteZone(
    BuildContext context,
    ThemeData theme, {
    required bool active,
  }) {
    return AnimatedScale(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      scale: active ? 1.06 : 1.0,
      child: Material(
        color: active
            ? theme.colorScheme.error
            : theme.colorScheme.errorContainer,
        shape: const StadiumBorder(),
        elevation: active ? 8 : 2,
        shadowColor: theme.colorScheme.error.withValues(alpha: 0.45),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.delete_rounded,
              size: 22,
              color: active
                  ? theme.colorScheme.onError
                  : theme.colorScheme.onErrorContainer,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.touch_app_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Text(
                context.l10n.progressGesture_emptySelection,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================== 可添加列表 ==============================

class _AvailableTile extends StatelessWidget {
  const _AvailableTile({
    required this.action,
    required this.enabled,
    required this.onTap,
  });

  final ProgressGestureAction action;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = progressGestureActionMeta(context, action);
    return ListTile(
      enabled: enabled,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        alignment: Alignment.center,
        child: Icon(
          meta.icon,
          size: 20,
          color: enabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.outline,
        ),
      ),
      title: Text(meta.label),
      trailing: Icon(
        Symbols.add_circle_rounded,
        color: enabled ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      onTap: enabled ? onTap : null,
    );
  }
}
