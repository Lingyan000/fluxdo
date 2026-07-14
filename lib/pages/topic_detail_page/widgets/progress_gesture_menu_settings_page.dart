import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../providers/preferences_provider.dart';
import '../../../widgets/common/radial_menu_fixed_slots.dart';
import 'progress_gesture_action_meta.dart';

/// 长按菜单功能设置页：
/// - 半圆固定 8 坑，坑位不随启用数量自动对齐
/// - 拖到指定坑 = 用户决定按钮进哪个坑
/// - 拖到中央删除区移除；下方列表点 + 填入最左空坑
class ProgressGestureMenuSettingsPage extends ConsumerStatefulWidget {
  const ProgressGestureMenuSettingsPage({super.key});

  @override
  ConsumerState<ProgressGestureMenuSettingsPage> createState() =>
      _ProgressGestureMenuSettingsPageState();
}

class _ProgressGestureMenuSettingsPageState
    extends ConsumerState<ProgressGestureMenuSettingsPage> {
  late List<ProgressGestureAction?> _slots;

  @override
  void initState() {
    super.initState();
    _slots = normalizeProgressGestureMenuSlots(
      ref.read(preferencesProvider).progressGestureMenuActions,
    );
  }

  int get _filledCount => progressGestureMenuFilledCount(_slots);

  Set<ProgressGestureAction> get _occupiedActions =>
      progressGestureMenuOccupiedActions(_slots).toSet();

  void _commit() {
    ref
        .read(preferencesProvider.notifier)
        .setProgressGestureMenuActions(_slots);
  }

  /// 点 +：放入最左空坑；8 坑都满则忽略。
  void _add(ProgressGestureAction action) {
    if (_occupiedActions.contains(action)) return;
    final empty = _slots.indexWhere((e) => e == null);
    if (empty < 0) return;
    setState(() {
      _slots = List<ProgressGestureAction?>.from(_slots);
      _slots[empty] = action;
    });
    _commit();
  }

  void _clearSlot(int slot) {
    if (slot < 0 || slot >= _slots.length) return;
    if (_slots[slot] == null) return;
    setState(() {
      _slots = List<ProgressGestureAction?>.from(_slots);
      _slots[slot] = null;
    });
    _commit();
  }

  /// 把 [fromSlot] 的动作放到 [toSlot]。
  /// 目标有动作时交换，保持「坑位由用户指定、不自动挤齐」。
  void _moveSlot(int fromSlot, int toSlot) {
    if (fromSlot == toSlot) return;
    if (fromSlot < 0 || fromSlot >= _slots.length) return;
    if (toSlot < 0 || toSlot >= _slots.length) return;
    if (_slots[fromSlot] == null) return;
    setState(() {
      _slots = List<ProgressGestureAction?>.from(_slots);
      final tmp = _slots[toSlot];
      _slots[toSlot] = _slots[fromSlot];
      _slots[fromSlot] = tmp;
    });
    _commit();
  }

  Future<void> _resetDefault() async {
    await ref
        .read(preferencesProvider.notifier)
        .resetProgressGestureMenuActions();
    if (!mounted) return;
    setState(() {
      _slots = normalizeProgressGestureMenuSlots(
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
    final occupied = _occupiedActions;
    final available = ProgressGestureAction.values
        .where((a) => a != ProgressGestureAction.none && !occupied.contains(a))
        .toList();
    final atLimit = _filledCount >= kProgressGestureMenuMax;
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
          Opacity(
            opacity: canEdit ? 1.0 : 0.4,
            child: IgnorePointer(
              ignoring: !canEdit,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: _PreviewArea(
                      slots: _slots,
                      onMove: _moveSlot,
                      onClear: _clearSlot,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: Text(
                      _filledCount == 0
                          ? l10n.progressGesture_emptySelection
                          : '$_filledCount/$kProgressGestureMenuMax · '
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
    required this.slots,
    required this.onMove,
    required this.onClear,
  });

  final List<ProgressGestureAction?> slots;
  final void Function(int fromSlot, int toSlot) onMove;
  final void Function(int slot) onClear;

  @override
  State<_PreviewArea> createState() => _PreviewAreaState();
}

class _PreviewAreaState extends State<_PreviewArea> {
  int? _draggingSlot;
  int? _hoverSlot;
  bool _hoverDelete = false;

  double get _previewRadius => RadialMenuFixedSlots.radius;

  Offset _itemPosition(int slot, Offset center) {
    return RadialMenuFixedSlots.positionForSlot(
      slot: slot,
      center: center,
      radius: _previewRadius,
    );
  }

  void _resetDragState() {
    if (_draggingSlot == null && _hoverSlot == null && !_hoverDelete) {
      return;
    }
    setState(() {
      _draggingSlot = null;
      _hoverSlot = null;
      _hoverDelete = false;
    });
  }

  void _handleHoverMove({
    required Offset globalPos,
    required RenderBox box,
    required Offset pillCenter,
    required Rect pillRect,
  }) {
    final localPos = box.globalToLocal(globalPos);

    if (pillRect.inflate(12).contains(localPos)) {
      if (!_hoverDelete || _hoverSlot != null) {
        setState(() {
          _hoverDelete = true;
          _hoverSlot = null;
        });
      }
      return;
    }

    // 8 固定坑都可命中（含空坑），用户决定放进哪个坑。
    final slot = RadialMenuFixedSlots.nearestSlot(
      pointer: localPos,
      center: pillCenter,
      pressArea: pillRect,
    );

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
    final slots = widget.slots;
    final filled = progressGestureMenuFilledCount(slots);
    final radius = _previewRadius;
    final height = radius + 32 + 40 + 16;

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
                widget.onClear(details.data);
              } else if (_hoverSlot != null) {
                widget.onMove(details.data, _hoverSlot!);
              }
              _resetDragState();
            },
            builder: (context, candidate, rejected) {
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // 始终画出 8 个固定坑位轮廓，空坑可见。
                  for (int slot = 0; slot < kProgressGestureMenuMax; slot++)
                    _buildPitMarker(
                      slot: slot,
                      pillCenter: pillCenter,
                      theme: theme,
                      occupied: slots[slot] != null,
                      highlighted:
                          _hoverSlot == slot &&
                          _draggingSlot != null &&
                          !_hoverDelete,
                    ),
                  // 已占用坑上的可拖动按钮
                  for (int slot = 0; slot < slots.length; slot++)
                    if (slots[slot] != null)
                      _buildSlotItem(
                        slot: slot,
                        action: slots[slot]!,
                        pillCenter: pillCenter,
                        theme: theme,
                      ),
                  Positioned.fromRect(
                    rect: pillRect,
                    child: _draggingSlot == null
                        ? _buildIdlePill(context, theme, filled)
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

  Widget _buildPitMarker({
    required int slot,
    required Offset pillCenter,
    required ThemeData theme,
    required bool occupied,
    required bool highlighted,
  }) {
    final pos = _itemPosition(slot, pillCenter);
    const size = 48.0;
    final borderColor = highlighted
        ? theme.colorScheme.primary
        : theme.colorScheme.outline.withValues(alpha: occupied ? 0.0 : 0.35);
    return Positioned(
      left: pos.dx - size / 2,
      top: pos.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: highlighted
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            border: Border.all(
              color: borderColor,
              width: highlighted ? 2 : 1.2,
              style: occupied && !highlighted
                  ? BorderStyle.none
                  : BorderStyle.solid,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSlotItem({
    required int slot,
    required ProgressGestureAction action,
    required Offset pillCenter,
    required ThemeData theme,
  }) {
    final pos = _itemPosition(slot, pillCenter);
    const itemSize = 48.0;
    return Positioned(
      key: ValueKey('slot_$slot'),
      left: pos.dx - itemSize / 2,
      top: pos.dy - itemSize / 2,
      width: itemSize,
      height: itemSize,
      child: LongPressDraggable<int>(
        data: slot,
        delay: const Duration(milliseconds: 200),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _buildItemChip(context, action, theme, dragging: true),
        childWhenDragging: _buildPlaceholder(theme),
        onDragStarted: () => setState(() => _draggingSlot = slot),
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

  Widget _buildIdlePill(BuildContext context, ThemeData theme, int filled) {
    return Material(
      color: theme.colorScheme.surface,
      shape: const StadiumBorder(),
      elevation: 2,
      shadowColor: Colors.black26,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$filled',
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
