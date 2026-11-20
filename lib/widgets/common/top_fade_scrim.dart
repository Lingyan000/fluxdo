import 'package:material_ui/material_ui.dart';

/// 顶栏渐隐遮罩：页面底色从状态栏下缘起向下渐隐到全透明，内容从其下
/// 滚过时自然淡出，没有硬下边。纯渐变，不读取背景、不跑 shader。
///
/// 用法：AppBar 设为纯透明（只承载返回/标题/按钮），本组件以
/// IgnorePointer 画在 body Stack 顶部，高度 = 状态栏 + AppBar +
/// 消散尾巴（尾巴伸出 AppBar 下缘，让渐隐收尾不露边）。
class TopFadeScrim extends StatelessWidget {
  const TopFadeScrim({
    super.key,
    required this.height,
    required this.solidHeight,
  });

  /// 总高（通常 = MediaQuery.padding.top + kToolbarHeight + [tail]）
  final double height;

  /// 保持最深的顶部区域（状态栏高度），其下开始渐隐
  final double solidHeight;

  /// 消散尾巴：伸出 AppBar 下缘的渐隐收尾区。
  static const double tail = 28;

  /// 页面接线用：遮罩总高 = 状态栏 + AppBar + 尾巴。
  static double heightFor(BuildContext context) => barHeightFor(context) + tail;

  /// 顶栏下缘（状态栏 + AppBar）。滚动内容的顶部避让基于此值再加间距：
  /// 遮罩只在内容滚到栏下时出现，首屏不必让出尾巴
  static double barHeightFor(BuildContext context) =>
      MediaQuery.paddingOf(context).top + kToolbarHeight;

  static const double _alpha = 0.9;
  static const int _fadeSteps = 8;

  Gradient _scrim(Color color) {
    final start = height <= 0 ? 0.0 : (solidHeight / height).clamp(0.0, 1.0);
    final stops = <double>[0];
    final colors = <Color>[color.withValues(alpha: _alpha)];
    for (var i = 0; i <= _fadeSteps; i++) {
      final t = i / _fadeSteps;
      stops.add(start + (1 - start) * t);
      colors.add(
        color.withValues(alpha: _alpha * (1 - Curves.easeInOut.transform(t))),
      );
    }
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: stops,
      colors: colors,
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: _scrim(Theme.of(context).colorScheme.surface),
          ),
        ),
      ),
    );
  }
}
