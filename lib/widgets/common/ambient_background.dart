import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 极光环境背景。
///
/// surface 底色 + 两个柔和模糊光斑(primary / secondary)缓慢游动, 暗色模式叠一层
/// 轻微暗化。用于 onboarding / 登录页等品牌页面的背景层。
/// 可选 [child] 叠在背景之上(铺满)。
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key, this.child});

  final Widget? child;

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final secondary = theme.colorScheme.secondary;
    final surface = theme.colorScheme.surface;

    return Container(
      color: surface,
      child: Stack(
        children: [
          Positioned(
            top: -100,
            left: -100,
            child: _AnimatedBlob(
              color: primary.withValues(alpha: isDark ? 0.15 : 0.08),
              size: 400,
              controller: _controller,
              offset: 0,
            ),
          ),
          Positioned(
            bottom: -100,
            right: -100,
            child: _AnimatedBlob(
              color: secondary.withValues(alpha: isDark ? 0.15 : 0.08),
              size: 350,
              controller: _controller,
              offset: math.pi,
            ),
          ),
          if (isDark)
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.2)),
            ),
          if (widget.child != null) Positioned.fill(child: widget.child!),
        ],
      ),
    );
  }
}

/// 氛围背景页面的角落图标按钮。
///
/// 半透明 surface 衬底 + 圆角 12，保证按钮浮在彩色光斑上时
/// 仍有清晰的可点击区域。onboarding / 登录页 / 启动失败页共用。
class AmbientIconButton extends StatelessWidget {
  const AmbientIconButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor:
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
    );
  }
}

class _AnimatedBlob extends StatelessWidget {
  const _AnimatedBlob({
    required this.color,
    required this.size,
    required this.controller,
    required this.offset,
  });

  final Color color;
  final double size;
  final AnimationController controller;
  final double offset;

  @override
  Widget build(BuildContext context) {
    // child 只建一次:100px 高斯模糊的大光斑重栅格化很贵,每帧只平移
    // 位置;RepaintBoundary 把光斑隔离成独立图层,平移不触发重绘。
    return AnimatedBuilder(
      animation: controller,
      child: RepaintBoundary(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(color: color, blurRadius: 100, spreadRadius: 50),
            ],
          ),
        ),
      ),
      builder: (context, child) {
        final angle = controller.value * 2 * math.pi + offset;
        final x = 30 * math.cos(angle);
        final y = 30 * math.sin(angle);
        return Transform.translate(offset: Offset(x, y), child: child);
      },
    );
  }
}
