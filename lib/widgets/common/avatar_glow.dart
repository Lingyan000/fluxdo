import 'package:material_ui/material_ui.dart';

/// 头像脉冲光晕效果
class AvatarGlow extends StatefulWidget {
  final Widget child;
  final Color glowColor;

  const AvatarGlow({
    super.key,
    required this.child,
    this.glowColor = const Color(0xFFF5BF03),
  });

  @override
  State<AvatarGlow> createState() => _AvatarGlowState();
}

class _AvatarGlowState extends State<AvatarGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary 隔离 60fps 的 blurRadius/opacity 脉冲动画,
    // 避免连累整个 post item / list item 重绘。
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // ease-in-out 曲线
          final t = Curves.easeInOut.transform(_controller.value);
          // 光晕半径在 8~20 之间脉冲
          final blurRadius = 8.0 + t * 12.0;
          // 透明度在 0.3~0.8 之间脉冲
          final opacity = 0.3 + t * 0.5;

          return Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.glowColor.withValues(alpha: opacity),
                  blurRadius: blurRadius,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
