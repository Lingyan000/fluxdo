import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:common_ui/common_ui.dart';

import '../providers/ai_provider_providers.dart';

/// 根据主题亮度返回模糊遮罩颜色
Color _blurBarrierColor(Brightness brightness) {
  return brightness == Brightness.dark
      ? const Color(0x47000000) // ~28% 黑
      : const Color(0x26000000); // ~15% 黑
}

/// 模糊效果目标 sigma 值（参考 Telegram 源码）
const _blurSigma = 25.0;

/// 饱和度增强系数（1.0 = 无变化，>1.0 增强饱和度）
const _saturationBoost = 1.3;

/// 饱和度增强的 ColorFilter 矩阵（基于 BT.709 亮度系数）
final ColorFilter _saturationFilter = () {
  const s = _saturationBoost;
  const sr = (1 - s) * 0.2126;
  const sg = (1 - s) * 0.7152;
  const sb = (1 - s) * 0.0722;
  return ColorFilter.matrix(<double>[
    sr + s, sg,     sb,     0, 0,
    sr,     sg + s, sb,     0, 0,
    sr,     sg,     sb + s, 0, 0,
    0,      0,      0,      1, 0,
  ]);
}();

/// 根据用户偏好判断是否启用模糊（读取主应用写入的 pref_dialog_blur key）
bool _isBlurEnabled(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  final prefs = container.read(aiSharedPreferencesProvider);
  return prefs.getBool('pref_dialog_blur') ?? false;
}

/// 创建模糊 + 饱和度增强的复合滤镜
ImageFilter _createBlurFilter(double sigma) {
  return ImageFilter.compose(
    outer: _saturationFilter,
    inner: ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.mirror,
    ),
  );
}

/// 构建带动画模糊效果的遮罩层
///
/// macOS/Windows acrylic 模式下 NavigationRail 背景透明，
/// BackdropFilter 对其模糊效果异常，因此跳过该区域并补 surface 底色。
Widget _buildAnimatedBlurBarrier({
  required Widget barrier,
  required Animation<double> animation,
}) {
  final hasAcrylicRail = Platform.isMacOS || Platform.isWindows;

  return AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = animation.value;
      if (t == 0) return child!;

      final sigma = (_blurSigma * t).clamp(0.01, _blurSigma);
      final filter = _createBlurFilter(sigma);

      // acrylic 模式下 NavigationRail 背景透明，需跳过并补底
      final showRail =
          hasAcrylicRail && MediaQuery.sizeOf(context).width > 600;
      if (showRail) {
        const railWidth = 72.0;
        return Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: railWidth,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceDim,
              ),
            ),
            Positioned.fill(
              left: railWidth,
              child: BackdropFilter(
                filter: filter,
                child: const SizedBox.expand(),
              ),
            ),
            child!,
          ],
        );
      }

      return BackdropFilter(filter: filter, child: child);
    },
    child: barrier,
  );
}

/// 替代 [showDialog]，自动根据用户偏好添加背景高斯模糊。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  bool blur = true,
}) {
  final enableBlur = blur && _isBlurEnabled(context);

  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: useRootNavigator).context,
  );

  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _BlurRawDialogRoute<T>(
      pageBuilder: (buildContext, animation, secondaryAnimation) {
        final Widget pageChild = Builder(builder: builder);
        return themes.wrap(SafeArea(child: pageChild));
      },
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor ??
          (enableBlur
              ? _blurBarrierColor(Theme.of(context).brightness)
              : Colors.black54),
      barrierLabel:
          barrierLabel ??
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 150),
      transitionBuilder: _buildMaterialDialogTransitions,
      settings: routeSettings,
      enableBlur: enableBlur,
    ),
  );
}

/// Material Design 标准对话框过渡动画
Widget _buildMaterialDialogTransitions(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
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
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool blur = true,
}) {
  final enableBlur = blur && _isBlurEnabled(context);
  final NavigatorState navigator =
      Navigator.of(context, rootNavigator: useRootNavigator);

  return navigator.push(
    _BlurModalBottomSheetRoute<T>(
      builder: builder,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      isScrollControlled: isScrollControlled,
      barrierLabel:
          barrierLabel ??
          MaterialLocalizations.of(context).modalBarrierDismissLabel,
      modalBarrierColor: barrierColor ??
          (enableBlur
              ? _blurBarrierColor(Theme.of(context).brightness)
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
    ),
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
    return _buildAnimatedBlurBarrier(
      barrier: barrier,
      animation: animation!,
    );
  }

  /// Android 预测返回手势:慢划边缘时 sheet 跟手下滑,与手指下拉关闭同
  /// 一套动画。与主 app 的同名 route 保持一致(本文件是那份的子包副本)。
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
  })  : _barrierDismissible = barrierDismissible,
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
      return _transitionBuilder!(context, animation, secondaryAnimation, child);
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
    return _buildAnimatedBlurBarrier(
      barrier: barrier,
      animation: animation!,
    );
  }
}
