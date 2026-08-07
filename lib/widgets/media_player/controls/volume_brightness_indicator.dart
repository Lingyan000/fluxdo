import 'package:flutter/material.dart';

import 'media_overlay_style.dart';

/// 竖滑/滚轮调音量、亮度时的居中 HUD:图标 + 横向进度条 + 百分比。
class VolumeBrightnessIndicator extends StatelessWidget {
  const VolumeBrightnessIndicator({
    super.key,
    required this.visible,
    required this.isVolume,
    required this.value,
  });

  final bool visible;

  /// true = 音量,false = 亮度。
  final bool isVolume;

  /// 0-1。
  final double value;

  IconData get _icon {
    if (!isVolume) return Icons.brightness_6_rounded;
    if (value <= 0.005) return Icons.volume_off_rounded;
    if (value < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return IgnorePointer(
      child: Center(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: AnimatedScale(
            scale: visible ? 1 : 0.9,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: MediaOverlayStyle.pill(radius: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_icon,
                      color: MediaOverlayStyle.foreground, size: 22),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    height: 3.5,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Stack(
                        children: [
                          const ColoredBox(color: Color(0x4DFFFFFF)),
                          // 用 FractionallySizedBox 替代 LinearProgressIndicator:
                          // 无 Material 内建动画插值,跟手零滞后
                          FractionallySizedBox(
                            widthFactor: clamped,
                            child:
                                const ColoredBox(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    // 容下最宽的「100%」(等宽数字),不够宽会折行
                    width: 42,
                    child: Text(
                      '${(clamped * 100).round()}%',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      softWrap: false,
                      style: const TextStyle(
                        color: MediaOverlayStyle.foreground,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
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
