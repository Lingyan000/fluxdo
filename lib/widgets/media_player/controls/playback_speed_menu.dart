import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import 'media_overlay_style.dart';

/// 可选倍速档位(视频/音频共用)。
const kPlaybackSpeedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 倍速数值展示:整数档去零(1x/2x),小数档保留(0.5x/1.25x)。
String formatPlaybackSpeed(double speed) {
  final text = speed == speed.roundToDouble()
      ? speed.toInt().toString()
      : speed.toString();
  return '${text}x';
}

/// 弹出倍速选择菜单(锚定在 [context] 对应的控件上),返回用户选择的
/// 倍速;取消返回 null。回调式设计,不绑任何播放器类型 —— 视频
/// (VideoPlayerController.setPlaybackSpeed)与音频(AudioPlayer.setSpeed)
/// 拿到返回值后各自应用。
Future<double?> showPlaybackSpeedMenu(
  BuildContext context, {
  required double current,
  bool darkOverlay = false,
}) {
  final box = context.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  RelativeRect position = const RelativeRect.fromLTRB(0, 0, 0, 0);
  if (box != null && overlay != null) {
    position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
  }

  final theme = Theme.of(context);
  // 媒体覆盖层(视频控制条)上弹菜单用深色玻璃质感(与 HUD/胶囊同一
  // 令牌),选中项琥珀强调;普通页面内(音频条)跟随应用主题。
  final Color? menuColor = darkOverlay ? const Color(0xF21A1A1A) : null;
  final Color itemColor =
      darkOverlay ? MediaOverlayStyle.foreground : theme.colorScheme.onSurface;
  final Color checkColor =
      darkOverlay ? MediaOverlayStyle.accent : theme.colorScheme.primary;

  return showMenu<double>(
    context: context,
    position: position,
    color: menuColor,
    elevation: darkOverlay ? 12 : null,
    shape: darkOverlay
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0x1FFFFFFF)),
          )
        : null,
    items: [
      for (final speed in kPlaybackSpeedOptions)
        PopupMenuItem<double>(
          value: speed,
          height: 40,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: speed == current
                    ? Icon(Icons.check_rounded, size: 18, color: checkColor)
                    : null,
              ),
              Text(
                speed == 1.0
                    ? '${formatPlaybackSpeed(speed)} '
                        '(${S.current.mediaPlayer_speedNormal})'
                    : formatPlaybackSpeed(speed),
                style: TextStyle(
                  color: speed == current && darkOverlay
                      ? MediaOverlayStyle.accent
                      : itemColor,
                  fontSize: 14,
                  fontWeight:
                      speed == current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
