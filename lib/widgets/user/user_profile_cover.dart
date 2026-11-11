import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../common/cached_image.dart';

/// 自定义封面优先，默认景深随主题的表面色与强调色实时绘制。
class UserProfileCover extends StatelessWidget {
  const UserProfileCover({super.key, this.imageUrl, required this.onTap});

  final String? imageUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final backdrop = RepaintBoundary(
      child: CustomPaint(
        painter: _ProfileCoverPainter(
          surface: scheme.surface,
          accent: context.emphasis.accent,
          secondary: scheme.secondary,
        ),
        child: const SizedBox.expand(),
      ),
    );
    final url = imageUrl;
    if (url == null || url.isEmpty) return ExcludeSemantics(child: backdrop);

    return Semantics(
      button: true,
      label: context.l10n.userProfile_viewBackground,
      child: InkWell(
        onTap: onTap,
        child: CachedImage(
          url: url,
          fit: BoxFit.cover,
          placeholder: (_) => backdrop,
          errorBuilder: (_, _, _) => backdrop,
        ),
      ),
    );
  }
}

class _ProfileCoverPainter extends CustomPainter {
  const _ProfileCoverPainter({
    required this.surface,
    required this.accent,
    required this.secondary,
  });

  final Color surface;
  final Color accent;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final wash = Color.alphaBlend(accent.withValues(alpha: 0.16), surface);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            wash,
            Color.alphaBlend(secondary.withValues(alpha: 0.06), surface),
            surface,
          ],
        ).createShader(bounds),
    );

    final width = size.width;
    final height = size.height;
    final distant = Path()
      ..moveTo(0, height * 0.62)
      ..cubicTo(
        width * 0.18,
        height * 0.46,
        width * 0.28,
        height * 0.77,
        width * 0.48,
        height * 0.59,
      )
      ..cubicTo(
        width * 0.69,
        height * 0.38,
        width * 0.8,
        height * 0.61,
        width,
        height * 0.47,
      )
      ..lineTo(width, height)
      ..lineTo(0, height)
      ..close();
    canvas.drawPath(
      distant,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0.10), accent.withValues(alpha: 0)],
        ).createShader(bounds),
    );

    final near = Path()
      ..moveTo(0, height * 0.84)
      ..cubicTo(
        width * 0.24,
        height * 0.66,
        width * 0.35,
        height * 0.91,
        width * 0.61,
        height * 0.73,
      )
      ..quadraticBezierTo(width * 0.83, height * 0.56, width, height * 0.69)
      ..lineTo(width, height)
      ..lineTo(0, height)
      ..close();
    canvas.drawPath(
      near,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [secondary.withValues(alpha: 0.12), surface],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_ProfileCoverPainter oldDelegate) =>
      surface != oldDelegate.surface ||
      accent != oldDelegate.accent ||
      secondary != oldDelegate.secondary;
}
