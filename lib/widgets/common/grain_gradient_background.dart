import 'package:flutter/material.dart';
import 'package:paper_shaders/paper_shaders.dart';

/// 基于主题色的 GrainGradient 背景组件
///
/// 包含 corners 形状的 shader 动画 + 3 层径向渐变辉光。
/// 颜色从 [Theme.of(context).colorScheme] 动态获取。
class GrainGradientBackground extends StatelessWidget {
  const GrainGradientBackground({super.key, this.animated = true});

  /// 是否持续播放 shader 动画；关闭只固定时间轴，不降低渲染质量。
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Stack(
      fit: StackFit.expand,
      children: [
        GrainGradient(
          colors: [
            colorScheme.primary,
            colorScheme.tertiary,
            colorScheme.secondary,
            colorScheme.primary.withValues(alpha: 0),
          ],
          backgroundColor: const Color(0xFF000000),
          shape: GrainGradientShape.corners,
          softness: 1.0,
          intensity: 0.9,
          noise: 0.5,
          animated: animated,
        ),
        // 径向渐变辉光（叠在 shader 上方）
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.6, -0.7),
              radius: 1.5,
              colors: [
                colorScheme.primary.withValues(alpha: 0.25),
                colorScheme.primary.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.6],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.4, -0.5),
              radius: 1.3,
              colors: [
                colorScheme.tertiary.withValues(alpha: 0.22),
                colorScheme.tertiary.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.55],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.1, 0.4),
              radius: 1.2,
              colors: [
                colorScheme.secondary.withValues(alpha: 0.18),
                colorScheme.secondary.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.6],
            ),
          ),
        ),
      ],
    );
  }
}
