import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/dialog_utils.dart';

/// 滑动操作按钮数据
class SwipeAction {
  final IconData icon;
  final Color color;
  final String? label;
  final Color foregroundColor;
  final VoidCallback onPressed;

  const SwipeAction({
    required this.icon,
    required this.color,
    required this.onPressed,
    this.label,
    this.foregroundColor = Colors.white,
  });
}

// ---------------------------------------------------------------------------
// SwipeActionScope — 管理同时只有一个项展开
// ---------------------------------------------------------------------------

class _SwipeActionNotifier extends ChangeNotifier {
  Key? _activeKey;
  Key? get activeKey => _activeKey;

  void requestCloseOthers(Key? activeKey) {
    _activeKey = activeKey;
    notifyListeners();
  }
}

class _SwipeActionScopeData extends InheritedWidget {
  final _SwipeActionNotifier notifier;

  const _SwipeActionScopeData({
    required this.notifier,
    required super.child,
  });

  static _SwipeActionScopeData? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_SwipeActionScopeData>();
  }

  @override
  bool updateShouldNotify(_SwipeActionScopeData oldWidget) =>
      notifier != oldWidget.notifier;
}

/// 包裹 ListView，确保同时只有一个 [SwipeActionCell] 展开
class SwipeActionScope extends StatefulWidget {
  final Widget child;
  const SwipeActionScope({super.key, required this.child});

  @override
  State<SwipeActionScope> createState() => _SwipeActionScopeState();
}

class _SwipeActionScopeState extends State<SwipeActionScope> {
  final _notifier = _SwipeActionNotifier();

  @override
  void dispose() {
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SwipeActionScopeData(notifier: _notifier, child: widget.child);
  }
}

// ---------------------------------------------------------------------------
// SwipeActionCell — 核心滑动组件
// ---------------------------------------------------------------------------

/// 仿 Telegram 风格的列表项滑动操作组件
///
/// 本组件自带卡片容器（圆角、阴影），child 不需要再包 Card。
/// 操作按钮和内容在同一个圆角容器内，滑动时内容区左移露出操作区。
class SwipeActionCell extends StatefulWidget {
  final Widget child;
  final List<SwipeAction> trailingActions;
  final double actionWidth;
  final double borderRadius;
  final bool enableLongPressMenu;

  const SwipeActionCell({
    super.key,
    required this.child,
    required this.trailingActions,
    this.actionWidth = 74.0,
    this.borderRadius = 16.0,
    this.enableLongPressMenu = true,
  });

  @override
  State<SwipeActionCell> createState() => _SwipeActionCellState();
}

class _SwipeActionCellState extends State<SwipeActionCell>
    with TickerProviderStateMixin {
  double _dragExtent = 0.0;
  bool _isExpanded = false;

  late AnimationController _animController;
  late AnimationController _shakeController;
  Animation<double>? _animation;
  _SwipeActionNotifier? _scopeNotifier;

  double get _totalActionWidth =>
      widget.trailingActions.length * widget.actionWidth;

  static const double _velocityThreshold = 100.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newNotifier = _SwipeActionScopeData.of(context)?.notifier;
    if (newNotifier != _scopeNotifier) {
      _scopeNotifier?.removeListener(_onScopeNotify);
      _scopeNotifier = newNotifier;
      _scopeNotifier?.addListener(_onScopeNotify);
    }
  }

  @override
  void dispose() {
    _scopeNotifier?.removeListener(_onScopeNotify);
    _animController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _onScopeNotify() {
    if (_scopeNotifier?.activeKey != widget.key && _dragExtent != 0) {
      _animateTo(0);
    }
  }

  // -- 手势 --

  void _onDragStart(DragStartDetails details) {
    _animController.stop();
    _animation = null;
    _scopeNotifier?.requestCloseOthers(widget.key);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragExtent += details.primaryDelta ?? 0;
      _dragExtent =
          _dragExtent.clamp(-MediaQuery.of(context).size.width * 0.8, 0.0);
    });

    final nowExpanded = _dragExtent.abs() > _totalActionWidth;
    if (nowExpanded != _isExpanded) {
      _isExpanded = nowExpanded;
      HapticFeedback.mediumImpact();
      if (_isExpanded) {
        _shakeController.forward(from: 0);
      } else {
        _shakeController.reset();
      }
    }
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;

    if (_isExpanded && widget.trailingActions.isNotEmpty) {
      _animateTo(0, onComplete: widget.trailingActions.last.onPressed);
      _isExpanded = false;
      return;
    }

    bool shouldOpen;
    if (velocity.abs() > _velocityThreshold) {
      shouldOpen = velocity < 0;
    } else {
      shouldOpen = _dragExtent.abs() > _totalActionWidth * 0.5;
    }

    _animateTo(shouldOpen ? -_totalActionWidth : 0.0);
    _isExpanded = false;
  }

  void _animateTo(double target, {VoidCallback? onComplete}) {
    final begin = _dragExtent;
    if ((begin - target).abs() < 0.5) {
      setState(() => _dragExtent = target);
      onComplete?.call();
      return;
    }

    _animController.reset();
    final anim = Tween<double>(begin: begin, end: target).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animation = anim;
    anim.addListener(() {
      if (_animation == anim) {
        setState(() => _dragExtent = anim.value);
      }
    });

    if (onComplete != null) {
      void statusListener(AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          onComplete();
          _animController.removeStatusListener(statusListener);
        }
      }
      _animController.addStatusListener(statusListener);
    }

    _animController.forward();
  }

  void _closeActions() {
    if (_dragExtent != 0) _animateTo(0);
  }

  void _onLongPress() {
    HapticFeedback.mediumImpact();
    _closeActions();
    final actions = widget.trailingActions;
    if (actions.isEmpty) return;
    final theme = Theme.of(context);

    showAppBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: actions.map((action) {
                  return ListTile(
                    leading: Icon(action.icon, color: action.color),
                    title: Text(
                      action.label ?? '',
                      style: TextStyle(color: action.color),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      action.onPressed();
                    },
                  );
                }).toList(),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revealWidth = _dragExtent.abs();
    final hasReveal = revealWidth > 0.5;

    return GestureDetector(
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onLongPress: widget.enableLongPressMenu ? _onLongPress : null,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: SizedBox(
          child: Stack(
            children: [
              if (hasReveal)
                Positioned.fill(
                  child: ColoredBox(
                    color: _actionBackgroundColor(revealWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: _buildActionButtons(revealWidth),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(_dragExtent, 0),
                child: GestureDetector(
                  onTap: hasReveal ? _closeActions : null,
                  child: Material(
                    color: theme.cardTheme.color ??
                        theme.colorScheme.surfaceContainerLow,
                    elevation: theme.cardTheme.elevation ?? 1,
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    clipBehavior: hasReveal ? Clip.antiAlias : Clip.none,
                    child: widget.child,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _actionBackgroundColor(double revealWidth) {
    final actions = widget.trailingActions;
    if (actions.length <= 1) return actions.first.color;
    final expandProgress =
        ((revealWidth - _totalActionWidth) / widget.actionWidth)
            .clamp(0.0, 1.0);
    return expandProgress >= 1.0 ? actions.last.color : actions.first.color;
  }

  /// 扩展模式下最后一个按钮的图标抖一下
  Widget _buildActionIcon(SwipeAction action, bool isLast, double expandProgress) {
    final icon = Icon(action.icon, color: action.foregroundColor, size: 22);
    if (!isLast || expandProgress <= 0) return icon;

    return AnimatedBuilder(
      animation: _shakeController,
      builder: (context, child) {
        final t = _shakeController.value;
        // 衰减抖动：3 次振荡，幅度从 0.18 逐渐减到 0
        final damping = 1.0 - t; // 1 → 0
        final angle = damping * 0.18 * _sin(t * 3 * 3.14159 * 2);
        return Transform.scale(
          scale: 1.0 + damping * 0.12,
          child: Transform.rotate(angle: angle, child: child),
        );
      },
      child: icon,
    );
  }

  /// 避免 import dart:math
  static double _sin(double x) {
    // Taylor 近似足够用于小范围抖动
    x = x % (2 * 3.14159265);
    if (x > 3.14159265) x -= 2 * 3.14159265;
    final x2 = x * x;
    return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42)));
  }

  List<Widget> _buildActionButtons(double revealWidth) {
    final actions = widget.trailingActions;
    if (actions.isEmpty) return [];

    final expandProgress =
        ((revealWidth - _totalActionWidth) / widget.actionWidth)
            .clamp(0.0, 1.0);
    final isExpanding = expandProgress > 0;
    final lastIndex = actions.length - 1;

    return List.generate(actions.length, (i) {
      final action = actions[i];
      final isLast = i == lastIndex;

      double buttonWidth;
      if (isExpanding) {
        if (isLast) {
          buttonWidth = revealWidth -
              (actions.length - 1) *
                  widget.actionWidth *
                  (1 - expandProgress);
        } else {
          buttonWidth = widget.actionWidth * (1 - expandProgress);
        }
      } else {
        buttonWidth = revealWidth / actions.length;
        buttonWidth = buttonWidth.clamp(0.0, widget.actionWidth);
      }

      return SizedBox(
        width: buttonWidth,
        child: Material(
          color: action.color,
          child: InkWell(
            onTap: () {
              _animateTo(0);
              action.onPressed();
            },
            child: Center(
              child: buttonWidth < 36
                  ? const SizedBox.shrink()
                  : AnimatedOpacity(
                      opacity: buttonWidth < 48 ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 100),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildActionIcon(action, isLast, expandProgress),
                          if (action.label != null && buttonWidth >= 56) ...[
                            const SizedBox(height: 2),
                            Text(
                              action.label!,
                              style: TextStyle(
                                color: action.foregroundColor,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        ),
      );
    });
  }
}
