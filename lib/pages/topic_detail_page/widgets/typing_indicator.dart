import 'package:flutter/material.dart';
import '../../../providers/message_bus_providers.dart';
import '../../../widgets/common/smart_avatar.dart';

/// 正在输入动画指示器
class TypingIndicator extends StatefulWidget {
  final TextStyle? textStyle;
  final String text;

  const TypingIndicator({
    super.key,
    this.textStyle,
    this.text = '正在输入',
  });

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<int> _dotCount;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();

    _dotCount = StepTween(
      begin: 0,
      end: 3,
    ).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _dotCount,
      builder: (context, child) {
        return Text(
          '${widget.text}${'.' * (_dotCount.value + 1)}',
          style: widget.textStyle,
        );
      },
    );
  }
}

/// 正在输入头像群组（最多显示 3 个，多余显示 +N）
class TypingAvatars extends StatelessWidget {
  final List<TypingUser> users;

  const TypingAvatars({
    super.key,
    required this.users,
  });

  static const int maxVisible = 3;
  static const double avatarSize = 28.0;
  static const double overlap = 10.0;

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final visibleUsers = users.take(maxVisible).toList();
    final extraCount = users.length - maxVisible;

    final avatarsWidget = SizedBox(
      height: avatarSize,
      width: avatarSize +
          (visibleUsers.length - 1) * (avatarSize - overlap) +
          (extraCount > 0 ? avatarSize - overlap : 0),
      child: Stack(
        children: [
          // 头像
          for (int i = 0; i < visibleUsers.length; i++)
            Positioned(
              left: i * (avatarSize - overlap),
              child: SmartAvatar(
                imageUrl: visibleUsers[i].avatarTemplate.isNotEmpty
                    ? visibleUsers[i].getAvatarUrl(size: 56)
                    : null,
                radius: avatarSize / 2,
                fallbackText: visibleUsers[i].username,
                border: Border.all(
                  color: theme.colorScheme.surfaceContainerHighest,
                  width: 2,
                ),
              ),
            ),
          // +N 显示
          if (extraCount > 0)
            Positioned(
              left: visibleUsers.length * (avatarSize - overlap),
              child: Container(
                width: avatarSize,
                height: avatarSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primaryContainer,
                  border: Border.all(
                    color: theme.colorScheme.surfaceContainerHighest,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Text(
                    '+$extraCount',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          avatarsWidget,
          const SizedBox(width: 8),
          TypingIndicator(
            textStyle: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
