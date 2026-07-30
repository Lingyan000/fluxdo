import 'package:flutter/material.dart';
import 'reaction_chip.dart';

/// 群聊自定义图标(表情):圆形底色 + 放大的 emoji,对齐"设为群图标"后
/// 在列表/详情页头部替代默认头像的展示位置。
class GroupChannelIcon extends StatelessWidget {
  const GroupChannelIcon({super.key, required this.emoji, required this.radius});

  final String emoji;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: ReactionEmoji(name: emoji, size: radius * 1.1),
    );
  }
}
