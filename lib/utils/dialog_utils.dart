import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../providers/preferences_provider.dart';
import '../providers/shortcut_provider.dart';
import 'blur_config.dart';

/// 根据用户偏好判断是否启用模糊
bool _isBlurEnabled(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  final prefs = container.read(preferencesProvider);
  return prefs.dialogBlur;
}

/// 构建带动画模糊效果的遮罩层
///
/// 模糊强度跟随路由动画渐变，并叠加饱和度增强，
/// 实现类似 Telegram 的平滑模糊过渡。
///
/// macOS/Windows acrylic 模式下 NavigationRail 背景透明，
/// BackdropFilter 对其模糊效果异常，因此跳过该区域并补 surface 底色。
Widget _buildAnimatedBlurBarrier({
  required Widget barrier,
  required Animation<double> animation,
}) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = animation.value;
      if (t == 0) return child!;

      final sigma = (blurSigma * t).clamp(0.01, blurSigma);
      final filter = createBlurFilter(sigma);

      return BackdropFilter(filter: filter, child: child);
    },
    child: barrier,
  );
}

Future<T?> _pushShortcutManagedRoute<T>({
  required BuildContext context,
  required NavigatorState navigator,
  required Route<T> route,
  ShortcutSurfaceConfig? shortcutSurface,
}) {
  if (shortcutSurface == null) {
    return navigator.push(route);
  }

  final container = ProviderScope.containerOf(context, listen: false);
  final registry = container.read(shortcutSurfaceRegistryProvider.notifier);
  final owner = Object();

  registry.register(
    owner: owner,
    id: shortcutSurface.id,
    triggerAction: shortcutSurface.triggerAction,
    repeatActions: shortcutSurface.repeatActions,
    kind: shortcutSurface.kind,
    repeatBehavior: shortcutSurface.repeatBehavior,
    blocksShortcuts: shortcutSurface.blocksShortcuts,
    passthroughActions: shortcutSurface.passthroughActions,
    route: route,
    onClose: () {
      final routeNavigator = route.navigator;
      if (routeNavigator != null && (route.isCurrent || route.isActive)) {
        routeNavigator.pop();
      }
    },
    onFocus: () {
      final routeNavigator = route.navigator;
      if (routeNavigator == null || route.isCurrent) return;
      routeNavigator.popUntil((candidate) => identical(candidate, route));
    },
  );

  return navigator.push(route).whenComplete(() {
    registry.unregister(owner: owner);
  });
}

Future<T?> pushAppRoute<T>({
  required BuildContext context,
  required Route<T> route,
  bool useRootNavigator = true,
  ShortcutSurfaceConfig? shortcutSurface,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return _pushShortcutManagedRoute(
    context: context,
    navigator: navigator,
    route: route,
    shortcutSurface: shortcutSurface,
  );
}

/// 替代 [showDialog]，自动根据用户偏好添加背景高斯模糊。
///
/// API 与 [showDialog] 基本一致，额外支持 [blur] 参数控制是否启用模糊
/// （默认 true，即跟随用户设置；设为 false 则强制不模糊）。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  bool blur = true,
  Duration transitionDuration = const Duration(milliseconds: 150),
  ShortcutSurfaceConfig? shortcutSurface,
}) {
  final enableBlur = blur && _isBlurEnabled(context);
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);

  final themes = InheritedTheme.capture(from: context, to: navigator.context);

  final route = _BlurRawDialogRoute<T>(
    pageBuilder: (buildContext, animation, secondaryAnimation) {
      final Widget pageChild = Builder(builder: builder);
      return themes.wrap(SafeArea(child: pageChild));
    },
    barrierDismissible: barrierDismissible,
    barrierColor:
        barrierColor ??
        (enableBlur
            ? blurBarrierColor(Theme.of(context).brightness)
            : Colors.black54),
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: transitionDuration,
    transitionBuilder: _buildMaterialDialogTransitions,
    settings: routeSettings,
    enableBlur: enableBlur,
  );

  return _pushShortcutManagedRoute(
    context: context,
    navigator: navigator,
    route: route,
    shortcutSurface: shortcutSurface,
  );
}

/// 替代 [showGeneralDialog]，自动根据用户偏好添加背景高斯模糊。
Future<T?> showAppGeneralDialog<T extends Object?>({
  required BuildContext context,
  required RoutePageBuilder pageBuilder,
  bool barrierDismissible = false,
  String? barrierLabel,
  Color? barrierColor,
  Duration transitionDuration = const Duration(milliseconds: 200),
  RouteTransitionsBuilder? transitionBuilder,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  bool blur = true,
  ShortcutSurfaceConfig? shortcutSurface,
}) {
  final enableBlur = blur && _isBlurEnabled(context);
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = _BlurRawDialogRoute<T>(
    pageBuilder: pageBuilder,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor:
        barrierColor ??
        (enableBlur
            ? blurBarrierColor(Theme.of(context).brightness)
            : const Color(0x80000000)),
    transitionDuration: transitionDuration,
    transitionBuilder: transitionBuilder,
    settings: routeSettings,
    enableBlur: enableBlur,
  );

  return _pushShortcutManagedRoute(
    context: context,
    navigator: navigator,
    route: route,
    shortcutSurface: shortcutSurface,
  );
}

/// Material Design 标准对话框过渡动画
Widget _buildMaterialDialogTransitions(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  // M3E:入场淡入 + 从 0.92 弹性放大(defaultSpatial 解析解,带轻微
  // 过冲的"落座感");退场纯淡出。关闭 M3E 时维持经典纯淡入。
  if (M3eFlags.of(context).enabled) {
    final scale = animation.status == AnimationStatus.reverse
        ? const AlwaysStoppedAnimation(1.0)
        : Tween<double>(begin: 0.92, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: _kDialogEnterCurve),
          );
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: ScaleTransition(scale: scale, child: child),
    );
  }
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}

/// 对话框入场弹簧曲线:defaultSpatial(0.8/380)在 250ms 窗口内的
/// 解析解,首峰轻微过冲(≈1.7%),收敛即落座。
final Curve _kDialogEnterCurve = M3eMotion.defaultSpatial.curveFor(
  const Duration(milliseconds: 250),
);

/// 替代 [showModalBottomSheet]，自动根据用户偏好添加背景高斯模糊。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool blur = true,
  ShortcutSurfaceConfig? shortcutSurface,
}) {
  final enableBlur = blur && _isBlurEnabled(context);
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );

  final route = _BlurModalBottomSheetRoute<T>(
    builder: builder,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    isScrollControlled: isScrollControlled,
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    modalBarrierColor:
        barrierColor ??
        (enableBlur
            ? blurBarrierColor(Theme.of(context).brightness)
            : Theme.of(context).bottomSheetTheme.modalBarrierColor),
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    backgroundColor: backgroundColor,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    settings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    useSafeArea: useSafeArea,
    sheetAnimationStyle: sheetAnimationStyle,
    enableBlur: enableBlur,
  );

  return _pushShortcutManagedRoute(
    context: context,
    navigator: navigator,
    route: route,
    shortcutSurface: shortcutSurface,
  );
}

/// 支持动画模糊的 ModalBottomSheetRoute 子类
class _BlurModalBottomSheetRoute<T> extends ModalBottomSheetRoute<T> {
  final bool enableBlur;

  _BlurModalBottomSheetRoute({
    required super.builder,
    super.capturedThemes,
    super.barrierLabel,
    super.backgroundColor,
    super.elevation,
    super.shape,
    super.clipBehavior,
    super.constraints,
    super.modalBarrierColor,
    super.isDismissible,
    super.enableDrag,
    super.showDragHandle,
    required super.isScrollControlled,
    super.settings,
    super.transitionAnimationController,
    super.anchorPoint,
    super.useSafeArea,
    super.sheetAnimationStyle,
    this.enableBlur = false,
  });

  @override
  Widget buildModalBarrier() {
    final barrier = super.buildModalBarrier();
    if (!enableBlur) return barrier;
    return _buildAnimatedBlurBarrier(barrier: barrier, animation: animation!);
  }
}

/// 支持动画模糊的 RawDialogRoute 替代
class _BlurRawDialogRoute<T> extends PopupRoute<T> {
  final RoutePageBuilder pageBuilder;
  final bool _barrierDismissible;
  final String? _barrierLabel;
  final Color _barrierColor;
  final Duration _transitionDuration;
  final RouteTransitionsBuilder? _transitionBuilder;
  final bool enableBlur;

  _BlurRawDialogRoute({
    required this.pageBuilder,
    required bool barrierDismissible,
    String? barrierLabel,
    required Color barrierColor,
    required Duration transitionDuration,
    RouteTransitionsBuilder? transitionBuilder,
    super.settings,
    this.enableBlur = false,
  }) : _barrierDismissible = barrierDismissible,
       _barrierLabel = barrierLabel,
       _barrierColor = barrierColor,
       _transitionDuration = transitionDuration,
       _transitionBuilder = transitionBuilder;

  @override
  bool get barrierDismissible => _barrierDismissible;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Color get barrierColor => _barrierColor;

  @override
  Duration get transitionDuration => _transitionDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return pageBuilder(context, animation, secondaryAnimation);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_transitionBuilder != null) {
      return _transitionBuilder(context, animation, secondaryAnimation, child);
    }
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.linear),
      child: child,
    );
  }

  @override
  Widget buildModalBarrier() {
    final barrier = super.buildModalBarrier();
    if (!enableBlur) return barrier;
    return _buildAnimatedBlurBarrier(barrier: barrier, animation: animation!);
  }
}
