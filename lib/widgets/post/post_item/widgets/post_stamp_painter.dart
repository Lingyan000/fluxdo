import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../l10n/s.dart';

/// 解决方案水印章（平铺 PostHeaderSection / 树形 NestedPostCard 共用）：
/// 已解决 = 绿色「已解决」+ verified 图标（opacity 0.12）；
/// 可采纳但未解决 = 灰色「未解决」+ help 图标（opacity 0.05）。
/// 旋转 -0.15° 模拟盖章效果，IgnorePointer 不挡正文交互。
class PostSolutionStamp extends StatelessWidget {
  /// true = 已是被采纳答案（绿章）；false = 可采纳但未解决（灰章）
  final bool accepted;

  const PostSolutionStamp({super.key, required this.accepted});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accepted ? Colors.green : theme.colorScheme.outline;
    return IgnorePointer(
      child: Opacity(
        opacity: accepted ? 0.12 : 0.05,
        child: Transform.rotate(
          angle: -0.15,
          child: CustomPaint(
            painter: PostStampPainter(color: color),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    accepted ? Symbols.verified_rounded : Symbols.help_rounded,
                    color: color,
                    size: 28,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    accepted
                        ? context.l10n.post_solved
                        : context.l10n.post_unsolved,
                    style: TextStyle(
                      color: color,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      fontFamily: theme.textTheme.titleLarge?.fontFamily,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 模拟印章残缺边框的绘制器
class PostStampPainter extends CustomPainter {
  final Color color;
  PostStampPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final path = Path();
    const double radius = 8;

    // 绘制残缺的矩形边框
    // 顶部边（部分）
    path.moveTo(size.width * 0.1, 0);
    path.lineTo(size.width - radius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, radius);

    // 右侧边（部分）
    path.lineTo(size.width, size.height * 0.7);

    // 底部边（从右向左，部分）
    path.moveTo(size.width * 0.8, size.height);
    path.lineTo(radius, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - radius);

    // 左侧边（部分）
    path.lineTo(0, size.height * 0.3);
    path.moveTo(0, size.height * 0.15);
    path.lineTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
