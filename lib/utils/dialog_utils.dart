import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../providers/preferences_provider.dart';
import '../providers/shortcut_provider.dart';
import '../services/dynamic_content_suspension_service.dart';

import 'package:common_ui/common_ui.dart';

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
  required ModalBlurScene scene,
  ValueListenable<bool>? blurReady,
}) {
  Widget buildBlur(double readiness) => AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = animation.value * readiness;
      if (t == 0) return child!;

      final sigma = (scene.sigma * t).clamp(0.01, scene.sigma);
      final filter = createBlurFilter(sigma);

      return BackdropFilter(filter: filter, child: child);
    },
    child: barrier,
  );
  if (blurReady == null) return buildBlur(1);
  return ValueListenableBuilder<bool>(
    valueListenable: blurReady,
    builder: (context, ready, _) => TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ready ? 1 : 0),
      duration:
          (MediaQuery.disableAnimationsOf(context) ||
              MediaQuery.reduceMotionOf(context))
          ? Duration.zero
          : const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      builder: (_, progress, _) => buildBlur(progress),
    ),
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

Future<T?> _pushOverlayRoute<T>({
  required BuildContext context,
  required NavigatorState navigator,
  required Route<T> route,
  required bool suspendDynamicContent,
  ShortcutSurfaceConfig? shortcutSurface,
}) {
  final lease = suspendDynamicContent
      ? DynamicContentSuspensionService.instance.acquire(
          reason: 'modal-overlay',
        )
      : null;
  return _pushShortcutManagedRoute(
    context: context,
    navigator: navigator,
    route: route,
    shortcutSurface: shortcutSurface,
  ).whenComplete(() => lease?.release());
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
/// [blurReady] 用于需要异步准备背景画面的原生视图；不阻塞弹层，
/// 就绪后才渐入整页模糊。未传入时保持普通弹层的动画行为。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  bool blur = true,
  ValueChanged<double>? onBlurSigmaChanged,
  ValueListenable<bool>? blurReady,
  bool filterBackdrop = true,
  Duration transitionDuration = const Duration(milliseconds: 150),
  ShortcutSurfaceConfig? shortcutSurface,
  bool suspendDynamicContent = true,
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
            ? blurBarrierColor(
                Theme.of(context).brightness,
                scene: ModalBlurScene.dialog,
              )
            : Colors.black54),
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: transitionDuration,
    transitionBuilder: _buildMaterialDialogTransitions,
    settings: routeSettings,
    enableBlur: enableBlur,
    onBlurSigmaChanged: onBlurSigmaChanged,
    blurReady: blurReady,
    filterBackdrop: filterBackdrop,
  );

  return _pushOverlayRoute(
    context: context,
    navigator: navigator,
    route: route,
    suspendDynamicContent: suspendDynamicContent,
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
  Duration? reverseTransitionDuration,
  RouteTransitionsBuilder? transitionBuilder,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  bool blur = true,
  ValueChanged<double>? onBlurSigmaChanged,
  ValueListenable<bool>? blurReady,
  bool filterBackdrop = true,
  ShortcutSurfaceConfig? shortcutSurface,
  bool suspendDynamicContent = true,
  VoidCallback? onDisposed,
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
            ? blurBarrierColor(
                Theme.of(context).brightness,
                scene: ModalBlurScene.dialog,
              )
            : const Color(0x80000000)),
    transitionDuration: transitionDuration,
    reverseTransitionDuration: reverseTransitionDuration,
    transitionBuilder: transitionBuilder,
    settings: routeSettings,
    enableBlur: enableBlur,
    onBlurSigmaChanged: onBlurSigmaChanged,
    blurReady: blurReady,
    filterBackdrop: filterBackdrop,
    onDisposed: onDisposed,
  );

  return _pushOverlayRoute(
    context: context,
    navigator: navigator,
    route: route,
    suspendDynamicContent: suspendDynamicContent,
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

/// 从页面上某个元素「长大」成底部弹层（容器变形）：弹层的外形从
/// [fromRect]（全局坐标、圆角 [fromRadius]、底色 [fromColor]）连续变形到
/// 屏幕底部 [heightFactor] 高度、顶部圆角 [toRadius] 的弹层，内容随后淡入；
/// 返回时原路缩回。用于输入框展开成完整编辑器等「一镜到底」的场景。
///
/// [builder] 的内容按全屏约束布局（与 isScrollControlled 的底部弹层一致），
/// 弹层自己负责只占底部 [heightFactor]。
Future<T?> showAppMorphSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required Rect fromRect,
  double fromRadius = 0,
  Color? fromColor,
  double toRadius = 16,
  double heightFactor = 0.95,
  ShortcutSurfaceConfig? shortcutSurface,
  bool suspendDynamicContent = true,
}) {
  final navigator = Navigator.of(context);
  final theme = Theme.of(context);
  final sheetConstraints =
      theme.bottomSheetTheme.constraints ?? const BoxConstraints(maxWidth: 640);
  // 路由内容按导航器自身坐标布局（嵌套导航器原点不在屏幕原点）
  final navigatorBox = navigator.context.findRenderObject() as RenderBox?;
  final localFrom = navigatorBox == null
      ? fromRect
      : fromRect.shift(-navigatorBox.localToGlobal(Offset.zero));
  final route = InteractionPageRouteBuilder<T>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: theme.bottomSheetTheme.modalBarrierColor ?? Colors.black54,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    // 与底部弹层同样的宽度上限（M3 默认 640）：桌面上不铺满整宽
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: sheetConstraints,
        child: builder(context),
      ),
    ),
    transitionsBuilder: (context, animation, _, child) => _MorphSheetTransition(
      animation: animation,
      fromRect: localFrom,
      fromRadius: fromRadius,
      fromColor: fromColor ?? theme.colorScheme.surfaceContainerHighest,
      toColor: theme.colorScheme.surface,
      toRadius: toRadius,
      heightFactor: heightFactor,
      maxWidth: sheetConstraints.maxWidth,
      child: child,
    ),
  );
  return _pushOverlayRoute(
    context: context,
    navigator: navigator,
    route: route,
    suspendDynamicContent: suspendDynamicContent,
    shortcutSurface: shortcutSurface,
  );
}

class _MorphSheetTransition extends StatelessWidget {
  const _MorphSheetTransition({
    required this.animation,
    required this.fromRect,
    required this.fromRadius,
    required this.fromColor,
    required this.toColor,
    required this.toRadius,
    required this.heightFactor,
    required this.maxWidth,
    required this.child,
  });

  final Animation<double> animation;
  final Rect fromRect;
  final double fromRadius;
  final Color fromColor;
  final Color toColor;
  final double toRadius;
  final double heightFactor;
  final double maxWidth;
  final Widget child;

  static const Curve _geometry = Curves.easeInOutCubicEmphasized;
  static const Curve _content = Interval(0.35, 1, curve: Curves.easeOut);
  static const Curve _fill = Interval(0.5, 1, curve: Curves.easeIn);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // 与 ReplySheet 的几何一致：顶部安全区之下、底部对齐的 heightFactor 高
        final width = size.width < maxWidth ? size.width : maxWidth;
        final left = (size.width - width) / 2;
        final toRect = Rect.fromLTRB(
          left,
          top + (size.height - top) * (1 - heightFactor),
          left + width,
          size.height,
        );
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) {
            final t = _geometry.transform(animation.value);
            final rect = Rect.lerp(fromRect, toRect, t)!;
            final topRadius = Radius.circular(
              lerpDouble(fromRadius, toRadius, t)!,
            );
            final bottomRadius = Radius.circular(lerpDouble(fromRadius, 0, t)!);
            final shape = RRect.fromRectAndCorners(
              rect,
              topLeft: topRadius,
              topRight: topRadius,
              bottomLeft: bottomRadius,
              bottomRight: bottomRadius,
            );
            final fillOpacity = 1 - _fill.transform(animation.value);
            return ClipPath(
              clipper: _RRectClipper(shape),
              child: Stack(
                children: [
                  if (fillOpacity > 0)
                    Positioned.fromRect(
                      rect: rect,
                      child: ColoredBox(
                        color: Color.lerp(
                          fromColor,
                          toColor,
                          t,
                        )!.withValues(alpha: fillOpacity),
                      ),
                    ),
                  Positioned.fill(
                    child: Opacity(
                      opacity: _content.transform(animation.value),
                      child: child,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _RRectClipper extends CustomClipper<Path> {
  const _RRectClipper(this.shape);

  final RRect shape;

  @override
  Path getClip(Size size) => Path()..addRRect(shape);

  @override
  bool shouldReclip(_RRectClipper oldClipper) => oldClipper.shape != shape;
}

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

  /// 在路由卸载时同步释放调用方持有的转场资源，包括导航器被整体销毁。
  VoidCallback? onDisposed,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool blur = true,
  ValueChanged<double>? onBlurSigmaChanged,
  ValueListenable<bool>? blurReady,
  bool filterBackdrop = true,
  ShortcutSurfaceConfig? shortcutSurface,
  bool suspendDynamicContent = true,
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
            ? blurBarrierColor(
                Theme.of(context).brightness,
                scene: ModalBlurScene.sheet,
              )
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
    onDisposed: onDisposed,
    anchorPoint: anchorPoint,
    useSafeArea: useSafeArea,
    sheetAnimationStyle: sheetAnimationStyle,
    enableBlur: enableBlur,
    onBlurSigmaChanged: onBlurSigmaChanged,
    blurReady: blurReady,
    filterBackdrop: filterBackdrop,
  );

  return _pushOverlayRoute(
    context: context,
    navigator: navigator,
    route: route,
    suspendDynamicContent: suspendDynamicContent,
    shortcutSurface: shortcutSurface,
  );
}

/// 将公共模糊动画同步给无法被 Flutter 背景取样的原生内容。
/// 跟随路由真实进度（包括拖动和预测返回），退出动画结束后再恢复清晰。
mixin _ModalBlurSync<T> on ModalRoute<T> {
  bool get enableBlur;
  ValueChanged<double>? get onBlurSigmaChanged;
  ModalBlurScene get blurScene;

  void _syncBlur() => onBlurSigmaChanged?.call(
    enableBlur ? blurScene.sigma * (animation?.value ?? 0).clamp(0.0, 1.0) : 0,
  );

  @override
  void install() {
    super.install();
    if (onBlurSigmaChanged != null) {
      animation?.addListener(_syncBlur);
      _syncBlur();
    }
  }

  @override
  void dispose() {
    animation?.removeListener(_syncBlur);
    onBlurSigmaChanged?.call(0);
    super.dispose();
  }
}

/// 支持动画模糊的 ModalBottomSheetRoute 子类
class _BlurModalBottomSheetRoute<T> extends ModalBottomSheetRoute<T>
    with _ModalBlurSync<T>, InterruptibleRoute<T> {
  @override
  final bool enableBlur;
  @override
  final ValueChanged<double>? onBlurSigmaChanged;
  final ValueListenable<bool>? blurReady;
  final bool filterBackdrop;
  final VoidCallback? onDisposed;
  @override
  ModalBlurScene get blurScene => ModalBlurScene.sheet;

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
    this.onBlurSigmaChanged,
    this.blurReady,
    this.filterBackdrop = true,
    this.onDisposed,
  });

  @override
  void dispose() {
    onDisposed?.call();
    super.dispose();
  }

  @override
  Widget buildModalBarrier() {
    final barrier = super.buildModalBarrier();
    if (!enableBlur || !filterBackdrop) return barrier;
    return _buildAnimatedBlurBarrier(
      barrier: barrier,
      animation: animation!,
      scene: ModalBlurScene.sheet,
      blurReady: blurReady,
    );
  }

  /// Android 预测返回手势:慢划边缘时 sheet 跟手下滑,与手指下拉关闭是同
  /// 一套动画 —— sheet 位移本就绑 route.animation(`_ModalBottomSheetState`
  /// 里 `_sheetAnimation.parent = widget.route.animation`),而官方的下拉
  /// 关闭改的是同一个 controller 的 value,手势进度喂进去即跟手,零新增
  /// 动画代码。ModalBottomSheetRoute 不重写 buildTransitions(继承
  /// ModalRoute 的默认实现 `return child`),故这里是干净的插入点;
  /// 只认领手势、不包任何视觉 widget。详见
  /// [wrapPredictiveBackForModalRoute] 与预测返回文件头的差异点 8。
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return wrapPredictiveBackForModalRoute(
      route: this,
      child: super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

/// 支持动画模糊的 RawDialogRoute 替代
class _BlurRawDialogRoute<T> extends PopupRoute<T>
    with _ModalBlurSync<T>, InterruptibleRoute<T> {
  final RoutePageBuilder pageBuilder;
  final bool _barrierDismissible;
  final String? _barrierLabel;
  final Color _barrierColor;
  final Duration _transitionDuration;
  final Duration? _reverseTransitionDuration;
  final RouteTransitionsBuilder? _transitionBuilder;
  @override
  final bool enableBlur;
  @override
  final ValueChanged<double>? onBlurSigmaChanged;
  final ValueListenable<bool>? blurReady;
  final bool filterBackdrop;
  @override
  ModalBlurScene get blurScene => ModalBlurScene.dialog;
  final VoidCallback? onDisposed;

  _BlurRawDialogRoute({
    required this.pageBuilder,
    required bool barrierDismissible,
    String? barrierLabel,
    required Color barrierColor,
    required Duration transitionDuration,
    Duration? reverseTransitionDuration,
    RouteTransitionsBuilder? transitionBuilder,
    super.settings,
    this.enableBlur = false,
    this.onBlurSigmaChanged,
    this.blurReady,
    this.filterBackdrop = true,
    this.onDisposed,
  }) : _barrierDismissible = barrierDismissible,
       _barrierLabel = barrierLabel,
       _barrierColor = barrierColor,
       _transitionDuration = transitionDuration,
       _reverseTransitionDuration = reverseTransitionDuration,
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
  Duration get reverseTransitionDuration =>
      _reverseTransitionDuration ?? _transitionDuration;

  @override
  void dispose() {
    onDisposed?.call();
    super.dispose();
  }

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
    final content = RouteContentInteraction(route: this, child: child);
    return RouteInputGate(
      route: this,
      child: _transitionBuilder != null
          ? _transitionBuilder(context, animation, secondaryAnimation, content)
          : FadeTransition(
              opacity: CurvedAnimation(parent: animation, curve: Curves.linear),
              child: content,
            ),
    );
  }

  @override
  Widget buildModalBarrier() {
    final barrier = super.buildModalBarrier();
    if (!enableBlur || !filterBackdrop) return barrier;
    return _buildAnimatedBlurBarrier(
      barrier: barrier,
      animation: animation!,
      scene: ModalBlurScene.dialog,
      blurReady: blurReady,
    );
  }
}
