import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../common/progressive_top_blur.dart';

/// 同一次用户滚动驱动顶栏和底栏；程序滚动与光标避让不参与。
class ComposerChromeController extends ChangeNotifier {
  bool _hidden = false;
  int _locks = 0;
  bool get hidden => _hidden;
  void reveal() {
    if (!_hidden) return;
    _hidden = false;
    notifyListeners();
  }

  void hide() {
    if (_hidden || _locks > 0) return;
    _hidden = true;
    notifyListeners();
  }

  VoidCallback hold() {
    _locks++;
    reveal();
    var released = false;
    return () {
      if (!released) {
        released = true;
        _locks--;
      }
    };
  }
}

class ComposerChromeScope extends StatefulWidget {
  const ComposerChromeScope({
    super.key,
    required this.controller,
    required this.child,
  });
  final ComposerChromeController controller;
  final Widget child;
  static ComposerChromeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ChromeScope>()?.notifier;
  @override
  State<ComposerChromeScope> createState() => _ComposerChromeScopeState();
}

class _ChromeScope extends InheritedNotifier<ComposerChromeController> {
  const _ChromeScope({required super.notifier, required super.child});
}

class _ComposerChromeScopeState extends State<ComposerChromeScope> {
  bool _userScroll = false;
  ScrollDirection _userDirection = ScrollDirection.idle;
  double _distance = 0;
  Offset? _down;
  bool _moved = false;

  bool _onScroll(ScrollNotification event) {
    if (event.depth != 0 || event.metrics.axis != Axis.vertical) return false;
    if (event is ScrollStartNotification) {
      _userScroll = event.dragDetails != null;
      _userDirection = ScrollDirection.idle;
      _distance = 0;
    }
    if (event is UserScrollNotification) {
      _userScroll = event.direction != ScrollDirection.idle;
      _userDirection = event.direction;
    }
    if (event is ScrollEndNotification) _userScroll = false;
    if (event is! ScrollUpdateNotification ||
        (!_userScroll && event.dragDetails == null)) {
      return false;
    }
    final metrics = event.metrics;
    final rawDelta = event.scrollDelta ?? 0;
    // 只累计文档范围内、与用户意图同向的移动；边界回弹不算反向阅读。
    final current = metrics.pixels.clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final previous = (metrics.pixels - rawDelta).clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final delta = (current - previous).toDouble();
    if (delta == 0 ||
        _userDirection == ScrollDirection.idle ||
        (_userDirection == ScrollDirection.reverse && delta < 0) ||
        (_userDirection == ScrollDirection.forward && delta > 0)) {
      return false;
    }
    if (metrics.pixels <= metrics.minScrollExtent + 4) {
      _distance = 0;
      widget.controller.reveal();
      return false;
    }
    if (_distance.sign != delta.sign) _distance = 0;
    _distance += delta;
    if (_distance > 36) widget.controller.hide();
    if (_distance < -18) widget.controller.reveal();
    return false;
  }

  @override
  Widget build(BuildContext context) => _ChromeScope(
    notifier: widget.controller,
    child: LayoutBuilder(
      builder: (context, bounds) => Listener(
        onPointerDown: (event) {
          _down = event.localPosition;
          _moved = false;
        },
        onPointerMove: (event) {
          if (_down != null && (event.localPosition - _down!).distance > 8) {
            _moved = true;
          }
        },
        onPointerUp: (_) {
          if (!_moved) widget.controller.reveal();
          _down = null;
        },
        onPointerCancel: (_) => _down = null,
        onPointerHover: (event) {
          if (event.localPosition.dy <
                  kToolbarHeight + MediaQuery.paddingOf(context).top ||
              event.localPosition.dy > bounds.maxHeight - 72) {
            widget.controller.reveal();
          }
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey != LogicalKeyboardKey.pageDown &&
                event.logicalKey != LogicalKeyboardKey.pageUp) {
              widget.controller.reveal();
            }
            return KeyEventResult.ignored;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}

class ComposerChromeVisibility extends StatelessWidget {
  const ComposerChromeVisibility({
    super.key,
    this.top = false,
    required this.child,
  });
  final bool top;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final controller = ComposerChromeScope.maybeOf(context);
    if (controller == null) return child;
    final hidden = controller.hidden;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return IgnorePointer(
      ignoring: hidden,
      child: ExcludeFocus(
        excluding: hidden,
        child: AnimatedSlide(
          offset: hidden ? Offset(0, top ? -1 : 1) : Offset.zero,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: hidden ? 0 : 1,
            duration: duration,
            child: child,
          ),
        ),
      ),
    );
  }
}

class ComposerAutoHideAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ComposerAutoHideAppBar({super.key, required this.child});
  final PreferredSizeWidget child;
  @override
  Size get preferredSize => child.preferredSize;
  @override
  Widget build(BuildContext context) =>
      ComposerChromeVisibility(top: true, child: child);
}

/// 顶栏收起后保留窄幅渐变，让滚出画面的文字自然消失。
class ComposerTopFade extends StatelessWidget {
  const ComposerTopFade({super.key, required this.height});
  final double height;
  @override
  Widget build(BuildContext context) {
    final hidden = ComposerChromeScope.maybeOf(context)?.hidden ?? false;
    return TweenAnimationBuilder<double>(
      tween: Tween(
        begin: height,
        end: hidden ? MediaQuery.viewPaddingOf(context).top + 24 : height,
      ),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => ProgressiveTopBlur(height: value),
    );
  }
}

/// 保留整幅滚动画布和编辑器的最小高度，只限制文字行宽。
class ComposerReadingPadding extends StatelessWidget {
  const ComposerReadingPadding({
    super.key,
    required this.child,
    this.vertical = EdgeInsets.zero,
  });
  final Widget child;
  final EdgeInsets vertical;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      math.max(20, (MediaQuery.sizeOf(context).width - 800) / 2),
      vertical.top,
      math.max(20, (MediaQuery.sizeOf(context).width - 800) / 2),
      vertical.bottom,
    ),
    child: child,
  );
}
