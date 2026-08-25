import 'package:flutter/material.dart';

/// 可拖动的分隔线组件
///
/// 内联于 Row 中，提供拖动调整相邻面板宽度的能力。
/// 包含完整的交互状态：悬停高亮、拖动高亮、光标锁定。
///
/// 使用方式：
/// ```dart
/// Row(
///   children: [
///     SizedBox(width: panelWidth, child: leftPanel),
///     DraggableDivider(
///       onResizeStart: () => _dragStartWidth = panelWidth,
///       onResizeUpdate: (globalX, startX) {
///         final desired = _dragStartWidth + (globalX - startX);
///         setState(() => panelWidth = desired.clamp(min, max));
///       },
///     ),
///     Expanded(child: rightPanel),
///   ],
/// )
/// ```
class DraggableDivider extends StatefulWidget {
  const DraggableDivider({
    super.key,
    required this.onResizeStart,
    required this.onResizeUpdate,
    this.onResizeEnd,
    this.hitWidth = 16,
    this.cursor = SystemMouseCursors.resizeColumn,
    this.showIdleLine = true,
  });

  /// 拖动开始回调，用于记录初始状态
  final VoidCallback onResizeStart;

  /// 拖动更新回调，参数为 (当前鼠标全局X, 拖动起始鼠标全局X)
  final void Function(double globalX, double startX) onResizeUpdate;

  /// 拖动结束回调
  final VoidCallback? onResizeEnd;

  /// 触控区域宽度（视觉上始终为细线）
  final double hitWidth;

  /// 拖动时的光标样式
  final MouseCursor cursor;

  /// 静止态是否画 1px 细线。宿主自己在接缝处画线时(胶片带按格子
  /// 实时位置画)传 false——本柄挂在**终态**栏宽处,层间动画期格子
  /// 还在飞,这条静止线会劈在运动画面中间;悬停/拖拽的高亮线不受
  /// 影响(那是交互反馈,理应贴手)。
  final bool showIdleLine;

  @override
  State<DraggableDivider> createState() => _DraggableDividerState();
}

class _DraggableDividerState extends State<DraggableDivider> {
  bool _hovering = false;
  bool _dragging = false;
  double? _dragStartX;
  OverlayEntry? _cursorOverlay;

  // ---- 光标锁定 ----

  void _lockCursor() {
    _cursorOverlay = OverlayEntry(
      builder: (_) => MouseRegion(
        cursor: widget.cursor,
        opaque: false,
        child: const SizedBox.expand(),
      ),
    );
    Overlay.of(context).insert(_cursorOverlay!);
  }

  void _unlockCursor() {
    _cursorOverlay?.remove();
    _cursorOverlay?.dispose();
    _cursorOverlay = null;
  }

  @override
  void dispose() {
    _unlockCursor();
    super.dispose();
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final double lineWidth;
    final Color lineColor;
    if (_dragging) {
      lineWidth = 3;
      lineColor = colorScheme.primary;
    } else if (_hovering) {
      lineWidth = 2;
      lineColor = colorScheme.primary.withAlpha(140);
    } else if (widget.showIdleLine) {
      lineWidth = 1;
      lineColor = colorScheme.outlineVariant;
    } else {
      lineWidth = 0;
      lineColor = Colors.transparent;
    }

    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) {
        if (!_dragging) setState(() => _hovering = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          _dragStartX = d.globalPosition.dx;
          setState(() => _dragging = true);
          _lockCursor();
          widget.onResizeStart();
        },
        onHorizontalDragUpdate: (d) {
          widget.onResizeUpdate(d.globalPosition.dx, _dragStartX!);
        },
        onHorizontalDragEnd: (_) {
          _unlockCursor();
          setState(() {
            _dragging = false;
            _hovering = false;
          });
          _dragStartX = null;
          widget.onResizeEnd?.call();
        },
        child: Center(
          child: Container(width: lineWidth, color: lineColor),
        ),
      ),
    );
  }
}
