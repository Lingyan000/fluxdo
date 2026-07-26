import 'package:flutter/widgets.dart';

/// 将小尾巴专属的动画策略传给签名 HTML/图片内部的 SVG 渲染器。
///
/// 使用作用域而不是修改通用图片回调，advanced HTML 中的内联 SVG 与普通
/// URL SVG 都能自动继承，同时正文和全屏查看器不会受到影响。
class SignatureAnimationScope extends InheritedWidget {
  const SignatureAnimationScope({
    super.key,
    required this.adaptiveFrameRate,
    required super.child,
  });

  final bool adaptiveFrameRate;

  static bool adaptiveFrameRateOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<SignatureAnimationScope>()
            ?.adaptiveFrameRate ??
        false;
  }

  @override
  bool updateShouldNotify(SignatureAnimationScope oldWidget) {
    return adaptiveFrameRate != oldWidget.adaptiveFrameRate;
  }
}
