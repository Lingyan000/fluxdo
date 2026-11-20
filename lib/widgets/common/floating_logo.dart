import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

/// 浮动发光 logo。
///
/// `assets/logo.svg` + 呼吸式上下浮动 + 主色发光圈。用于 onboarding / 登录页。
/// [size] 控制 logo 尺寸, [glowSize] 控制发光圈尺寸。
class FloatingLogo extends StatefulWidget {
  const FloatingLogo({super.key, this.size = 120, this.glowSize = 100});

  final double size;
  final double glowSize;

  @override
  State<FloatingLogo> createState() => _FloatingLogoState();
}

class _FloatingLogoState extends State<FloatingLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: -10.0, end: 10.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
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

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _animation.value),
          child: child,
        );
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          // logo 后的发光圈
          Container(
            width: widget.glowSize,
            height: widget.glowSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(
                    alpha: isDark ? 0.3 : 0.2,
                  ),
                  blurRadius: 60,
                  spreadRadius: 20,
                ),
              ],
            ),
          ),
          SizedBox(
            width: widget.size,
            height: widget.size,
            child: const AppSvgAsset('assets/logo.svg'),
          ),
        ],
      ),
    );
  }
}
