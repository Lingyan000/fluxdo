import 'dart:math' as math;

import 'package:chat_bottom_container/listener_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../utils/platform_utils.dart';
import '../common/top_fade_scrim.dart';
import 'composer_block_hover.dart';

/// 顶栏与底栏共享阅读态显隐；输入或面板交互期间保持可见。
class ComposerChromeController extends ChangeNotifier {
  /// 内容是否已滚到顶栏下面：顶栏胶囊的阴影与渐隐遮罩只在此时出现。
  /// 独立通知，不随显隐重建整个作用域
  final ValueNotifier<bool> scrolledUnder = ValueNotifier(false);

  bool _hidden = false;
  int _locks = 0;
  bool _inputActive = false;
  bool get hidden => _hidden;
  void beginInput() {
    _inputActive = true;
    reveal();
  }

  void endInput() => _inputActive = false;
  void reveal() {
    if (!_hidden) return;
    _hidden = false;
    notifyListeners();
  }

  void hide() {
    if (_hidden || _locks > 0 || _inputActive) return;
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

  @override
  void dispose() {
    scrolledUnder.dispose();
    super.dispose();
  }
}

class ComposerChromeScope extends StatefulWidget {
  const ComposerChromeScope({
    super.key,
    required this.controller,
    required this.child,
    this.topInset = 0,
  });
  final ComposerChromeController controller;
  final Widget child;
  final double topInset;
  static ComposerChromeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ChromeScope>()?.notifier;

  /// 首屏内容与顶栏下缘的间距（页面顶部避让 = 顶栏高 + 本值）
  static const double contentGap = 16;

  /// 内容碰到顶栏下缘时的滚动距离，即 [contentGap]。比自动隐藏的 36px
  /// 早，但两者只差一小段：往下拖时胶囊先浮起，紧接着整条栏收起
  static const double scrolledUnderExtent = contentGap;

  /// 不建立依赖：控制器在页面生命周期内不变，订阅方自己监听
  /// [ComposerChromeController.scrolledUnder]
  static ValueListenable<bool>? scrolledUnderOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<_ChromeScope>()
      ?.notifier
      ?.scrolledUnder;
  static double topInsetOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ChromeScope>()?.topInset ?? 0;
  @override
  State<ComposerChromeScope> createState() => _ComposerChromeScopeState();
}

class _ChromeScope extends InheritedNotifier<ComposerChromeController> {
  const _ChromeScope({
    required super.notifier,
    required super.child,
    required this.topInset,
  });
  final double topInset;
  @override
  bool updateShouldNotify(_ChromeScope oldWidget) =>
      topInset != oldWidget.topInset || super.updateShouldNotify(oldWidget);
}

class _ComposerChromeScopeState extends State<ComposerChromeScope> {
  bool _userScroll = false;
  ScrollDirection _userDirection = ScrollDirection.idle;
  double _distance = 0;
  Offset? _down;
  bool _moved = false;
  bool _keyboardVisible = false;
  late final String _keyboardListener;

  @override
  void initState() {
    super.initState();
    _keyboardListener = ChatBottomContainerListenerManager().register((height) {
      if (!mounted) return;
      // Native close notifications also cover floating/small-window keyboards
      // whose viewInsets were zero throughout the input session.
      if (height <= 0) {
        widget.controller.endInput();
      } else {
        widget.controller.beginInput();
      }
    });
  }

  @override
  void dispose() {
    ChatBottomContainerListenerManager().unregister(_keyboardListener);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_keyboardVisible && !visible) {
      widget.controller.endInput();
      // 键盘收起后可滚范围可能归零，不能再等一次反向滚动来恢复栏位。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _keyboardVisible) return;
        _userScroll = false;
        _userDirection = ScrollDirection.idle;
        _distance = 0;
        widget.controller.reveal();
      });
    }
    _keyboardVisible = visible;
  }

  bool _onScroll(ScrollNotification event) {
    if (event.depth != 0 || event.metrics.axis != Axis.vertical) return false;
    widget.controller.scrolledUnder.value =
        event.metrics.extentBefore > ComposerChromeScope.scrolledUnderExtent;
    if (_keyboardVisible) {
      widget.controller.reveal();
      return false;
    }
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
    topInset: widget.topInset,
    child: LayoutBuilder(
      builder: (context, bounds) => ComposerReadingGutter.page(
        width: bounds.maxWidth,
        child: Listener(
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
            onFocusChange: (focused) {
              if (!focused) widget.controller.endInput();
            },
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey != LogicalKeyboardKey.pageDown &&
                  event.logicalKey != LogicalKeyboardKey.pageUp) {
                widget.controller.reveal();
                if (event.character?.isNotEmpty == true ||
                    event.logicalKey == LogicalKeyboardKey.backspace ||
                    event.logicalKey == LogicalKeyboardKey.enter) {
                  widget.controller.beginInput();
                }
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
    ),
  );
}

/// A declarative visibility hold shared by keyboard, custom panel and menus.
class ComposerChromeActivity extends StatefulWidget {
  const ComposerChromeActivity({
    super.key,
    required this.active,
    required this.child,
  });
  final bool active;
  final Widget child;
  @override
  State<ComposerChromeActivity> createState() => _ComposerChromeActivityState();
}

class _ComposerChromeActivityState extends State<ComposerChromeActivity> {
  ComposerChromeController? _controller;
  ComposerChromeController? _held;
  VoidCallback? _release;
  bool _queued = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = ComposerChromeScope.maybeOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(covariant ComposerChromeActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final next = widget.active ? _controller : null;
      if (identical(next, _held)) return;
      _release?.call();
      _held = next;
      _release = next?.hold();
    });
  }

  @override
  void dispose() {
    _release?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    final duration =
        (MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.reduceMotionOf(context))
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

/// 顶栏收起后保留窄幅渐变，让滚出画面的文字自然消失；内容没滚到顶栏下面时
/// 遮罩淡出，静止的页面顶部保持干净。
class ComposerTopFade extends StatelessWidget {
  const ComposerTopFade({
    super.key,
    required this.height,
    required this.statusBarHeight,
  });
  final double height;
  // 从 Scaffold 外传入；body 内的 MediaQuery 已移除顶部安全区。
  final double statusBarHeight;
  @override
  Widget build(BuildContext context) {
    final hidden = ComposerChromeScope.maybeOf(context)?.hidden ?? false;
    final duration =
        (MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.reduceMotionOf(context))
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final scrim = TweenAnimationBuilder<double>(
      tween: Tween(begin: height, end: hidden ? statusBarHeight + 24 : height),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) =>
          TopFadeScrim(height: value, solidHeight: statusBarHeight),
    );
    final scrolledUnder = ComposerChromeScope.scrolledUnderOf(context);
    if (scrolledUnder == null) return scrim;
    return ValueListenableBuilder<bool>(
      valueListenable: scrolledUnder,
      builder: (context, under, child) => AnimatedOpacity(
        opacity: under ? 1 : 0,
        duration: duration,
        child: child,
      ),
      child: scrim,
    );
  }
}

/// 保留整幅滚动画布和编辑器的最小高度，只限制文字行宽。
class ComposerReadingGutter extends InheritedWidget {
  const ComposerReadingGutter({
    super.key,
    required this.leading,
    this.trailing = 20,
    required super.child,
  });

  /// 编辑页整页的正文边距（富文本与源码模式共用，切换模式文字不跳）：
  /// 手机为标准页边距 16；桌面端左侧是把手栏，块把手和顶栏返回键都在里面
  ComposerReadingGutter.page({
    super.key,
    required double width,
    required super.child,
  }) : leading = pageGutter(width),
       trailing = pageGutter(width);

  static double pageGutter(double width) => PlatformUtils.isDesktop
      ? ComposerBlockHover.gutterFor(width, desktop: true)
      : 16;
  final double leading;
  final double trailing;
  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ComposerReadingGutter>()
          ?.leading ??
      20;
  static double trailingOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ComposerReadingGutter>()
          ?.trailing ??
      20;
  @override
  bool updateShouldNotify(ComposerReadingGutter oldWidget) =>
      leading != oldWidget.leading || trailing != oldWidget.trailing;
}

class ComposerReadingPadding extends StatelessWidget {
  const ComposerReadingPadding({
    super.key,
    required this.child,
    this.vertical = EdgeInsets.zero,
    this.minLeading,
  });
  final Widget child;
  final EdgeInsets vertical;
  final double? minLeading;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      math.max(
        minLeading ?? ComposerReadingGutter.of(context),
        (MediaQuery.sizeOf(context).width - 800) / 2,
      ),
      vertical.top,
      math.max(
        ComposerReadingGutter.trailingOf(context),
        (MediaQuery.sizeOf(context).width - 800) / 2,
      ),
      vertical.bottom,
    ),
    child: child,
  );
}
