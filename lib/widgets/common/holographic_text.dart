import 'package:flutter/material.dart';

/// 全息渐变动画文字（模拟 CSS holographic 效果）
class HolographicText extends StatefulWidget {
  final String text;
  final double fontSize;

  const HolographicText({super.key, required this.text, required this.fontSize});

  @override
  State<HolographicText> createState() => _HolographicTextState();
}

class _HolographicTextState extends State<HolographicText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // 深色背景：高饱和亮色
  static const _darkColors = [
    Color(0xFFFF00FF), // magenta
    Color(0xFF00FFFF), // cyan
    Color(0xFFFFFF00), // yellow
    Color(0xFFFF00FF), // magenta
    Color(0xFF00FFFF), // cyan
  ];

  // 浅色背景：降低明度，保证可读性
  static const _lightColors = [
    Color(0xFFCC00CC), // dark magenta
    Color(0xFF0099AA), // dark cyan
    Color(0xFFCC8800), // dark gold
    Color(0xFFCC00CC), // dark magenta
    Color(0xFF0099AA), // dark cyan
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark ? _darkColors : _lightColors;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final offset = _controller.value;
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: colors,
              stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
              begin: Alignment(-1.0 + offset * 4, -1.0 + offset * 4),
              end: Alignment(1.0 + offset * 4, 1.0 + offset * 4),
              tileMode: TileMode.mirror,
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcIn,
          child: child!,
        );
      },
      child: Text(
        widget.text,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );
  }
}
