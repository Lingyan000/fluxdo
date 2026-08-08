import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../common/smart_avatar.dart';
import '../../providers/chat_providers.dart';

/// 带在线状态指示的头像组件
///
/// 包裹 SmartAvatar，根据用户 ID 和全局在线状态显示绿色指示圆点。
class OnlineStatusAvatar extends ConsumerWidget {
  final int? userId;
  final String? imageUrl;
  final double radius;
  final String? fallbackText;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final BoxBorder? border;

  const OnlineStatusAvatar({
    super.key,
    this.userId,
    this.imageUrl,
    required this.radius,
    this.fallbackText,
    this.backgroundColor,
    this.foregroundColor,
    this.border,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsState = ref.watch(chatChannelsProvider).value;
    final isOnline = userId != null &&
        channelsState != null &&
        channelsState.onlineUserIds.contains(userId);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        SmartAvatar(
          imageUrl: imageUrl,
          radius: radius,
          fallbackText: fallbackText,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          border: border,
        ),
        if (isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: radius * 0.4,
              height: radius * 0.4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF10B981), // emerald-500
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: radius * 0.08,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
