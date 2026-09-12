import 'dart:async';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'composer_tool_action.dart';
import '../../l10n/s.dart';

/// 工具栏两种编辑模式共用的转场来源；只记录实际可见的图标。
class ComposerToolsAnchor extends ChangeNotifier {
  List<ComposerToolAction> actions = const [];
  List<String> pinnedIds = const [];
  final targets = <String, GlobalKey>{};
  Completer<ComposerToolAction?>? _result;
  bool expanded = false;
  bool restoreInput = true;
  bool customizing = false;
  ComposerToolAction? _picked;
  Animation<double>? animation;
  bool get presenting => _result != null;

  Future<ComposerToolAction?> expand(
    List<ComposerToolAction> items,
    List<String> pinned,
  ) {
    if (_result != null) return _result!.future;
    actions = items;
    pinnedIds = pinned;
    targets.clear();
    _picked = null;
    customizing = false;
    restoreInput = true;
    _result = Completer<ComposerToolAction?>();
    expanded = true;
    notifyListeners();
    return _result!.future;
  }

  void collapse([ComposerToolAction? picked]) =>
      _collapse(picked, restore: true);

  /// 离开输入、预览或系统返回时收起工具，不重新弹出键盘。
  void dismiss() => _collapse(null, restore: false);

  void _collapse(ComposerToolAction? picked, {required bool restore}) {
    if (_result == null ||
        (!expanded && restoreInput == restore && _picked == picked)) {
      return;
    }
    _picked = picked;
    restoreInput = restore;
    expanded = false;
    notifyListeners();
  }

  /// 收起尚未结束时可以反向展开，继续使用同一次展开会话。
  void reopen() {
    if (_result == null || expanded) return;
    _picked = null;
    restoreInput = true;
    expanded = true;
    notifyListeners();
  }

  void finish() {
    final result = _result;
    _result = null;
    expanded = false;
    animation = null;
    targets.clear();
    result?.complete(_picked);
    if (result != null) notifyListeners();
  }

  void toggleCustomizing() {
    customizing = !customizing;
    notifyListeners();
  }

  @override
  void dispose() {
    finish();
    super.dispose();
  }

  final surfaceKey = GlobalKey();
  final _icons = <String, GlobalKey>{};

  Widget icon(String id, Widget child) => AnimatedBuilder(
    animation: this,
    builder: (_, _) => Opacity(
      opacity: presenting ? 0 : 1,
      child: KeyedSubtree(
        key: _icons.putIfAbsent(id, GlobalKey.new),
        child: child,
      ),
    ),
  );

  /// 迁移中的工具保留布局位置，但不能留下不可见的点击区域。
  Widget compactControl(Widget child) => AnimatedBuilder(
    animation: this,
    builder: (_, child) => IgnorePointer(
      ignoring: presenting,
      child: ExcludeFocus(
        excluding: presenting,
        child: Opacity(opacity: presenting ? 0 : 1, child: child),
      ),
    ),
    child: child,
  );

  Rect? get rect {
    final box = surfaceKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Map<String, Rect> visibleIcons() {
    final result = <String, Rect>{};
    for (final entry in _icons.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final iconRect = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      var visible = iconRect;
      RenderObject descendant = box;
      for (var parent = box.parent; parent != null; parent = parent.parent) {
        final clip = parent.describeApproximatePaintClip(descendant);
        if (clip != null) {
          visible = visible.intersect(
            MatrixUtils.transformRect(parent.getTransformTo(null), clip),
          );
        }
        descendant = parent;
      }
      // 半个图标不参与飞行，避免把滚动区外的工具带进来。
      if (!visible.isEmpty &&
          visible.width >= iconRect.width - .5 &&
          visible.height >= iconRect.height - .5) {
        result[entry.key] = iconRect;
      }
    }
    return result;
  }
}

class ComposerToolsToggle extends StatelessWidget {
  const ComposerToolsToggle({
    super.key,
    this.anchor,
    required this.active,
    required this.compact,
    this.onPressed,
  });
  final ComposerToolsAnchor? anchor;
  final bool active;
  final bool compact;
  final VoidCallback? onPressed;
  Widget _button(BuildContext context) {
    final done = compact && anchor?.customizing == true;
    final expanded = anchor?.expanded ?? active;
    return IconButton(
      icon: Icon(
        done
            ? Symbols.check_rounded
            : expanded
            ? Symbols.expand_more_rounded
            : Symbols.expand_less_rounded,
      ),
      tooltip: done
          ? S.current.common_done
          : expanded
          ? S.current.composer_collapseToolbar
          : S.current.composer_expandToolbar,
      color: active ? Theme.of(context).colorScheme.primary : null,
      onPressed: done ? anchor?.toggleCustomizing : onPressed,
    );
  }

  @override
  Widget build(BuildContext context) => anchor == null
      ? _button(context)
      : AnimatedBuilder(
          animation: anchor!,
          builder: (context, _) => _button(context),
        );
}

/// 展开时复用底栏原有工具槽，不额外增加自定义按钮行。
class ComposerCompactTools extends StatelessWidget {
  const ComposerCompactTools({
    super.key,
    required this.anchor,
    required this.child,
  });
  final ComposerToolsAnchor? anchor;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final controller = anchor;
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (_, child) => Stack(
        fit: StackFit.passthrough,
        children: [
          IgnorePointer(
            ignoring: controller.presenting,
            child: ExcludeFocus(
              excluding: controller.presenting,
              child: Opacity(
                opacity: controller.presenting ? 0 : 1,
                child: child,
              ),
            ),
          ),
          if (controller.presenting)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedBuilder(
                  animation:
                      controller.animation ?? const AlwaysStoppedAnimation(1.0),
                  builder: (_, child) {
                    // 工具离开后才显示；收起前 20% 就让出原位置，避免返程重叠。
                    final opacity = const Interval(
                      .8,
                      1,
                      curve: Curves.easeInCubic,
                    ).transform(controller.animation?.value ?? 1);
                    final interactive = controller.expanded && opacity == 1;
                    return IgnorePointer(
                      ignoring: !interactive,
                      child: ExcludeFocus(
                        excluding: !interactive,
                        child: Opacity(
                          key: const ValueKey('composer-customize-visibility'),
                          opacity: opacity,
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: TextButton.icon(
                    onPressed: controller.toggleCustomizing,
                    icon: Icon(
                      controller.customizing
                          ? Icons.check
                          : Icons.edit_outlined,
                      size: 16,
                    ),
                    label: Text(
                      controller.customizing
                          ? S.current.common_done
                          : S.current.toolPanel_customize,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 手机上下滑的明确入口，也可点按，键盘和读屏不依赖手势。
class ComposerToolsHandle extends StatefulWidget {
  const ComposerToolsHandle({
    super.key,
    required this.label,
    required this.onActivate,
    this.expanded = false,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });
  final String label;
  final VoidCallback onActivate;
  final bool expanded;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final VoidCallback? onDragCancel;
  static const height = 24.0;
  @override
  State<ComposerToolsHandle> createState() => _ComposerToolsHandleState();
}

class _ComposerToolsHandleState extends State<ComposerToolsHandle> {
  double _travel = 0;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    onTap: widget.onActivate,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (details) {
        _travel = 0;
        widget.onDragStart?.call(details);
      },
      onVerticalDragUpdate: (details) {
        _travel += details.delta.dy;
        widget.onDragUpdate?.call(details);
      },
      onVerticalDragCancel: widget.onDragCancel,
      onVerticalDragEnd: (details) {
        if (widget.onDragEnd != null) {
          widget.onDragEnd!(details);
          return;
        }
        final sign = widget.expanded ? 1 : -1;
        if (_travel * sign > 20 ||
            (details.primaryVelocity ?? 0) * sign > 240) {
          widget.onActivate();
        }
      },
      child: InkWell(
        onTap: widget.onActivate,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: ComposerToolsHandle.height,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
