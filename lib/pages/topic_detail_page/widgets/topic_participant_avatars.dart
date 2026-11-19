import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../../models/topic.dart';
import '../../../widgets/common/smart_avatar.dart';

/// 话题统计和私信成员入口共用的叠放头像，名单顺序从起始边读起。
class TopicParticipantAvatars extends StatelessWidget {
  const TopicParticipantAvatars({
    super.key,
    required this.users,
    this.groupCount = 0,
    this.size = 21,
    this.backgroundColor,
    this.foregroundColor,
  });

  final Iterable<TopicUser> users;
  final int groupCount;
  final double size;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ring = Border.all(color: scheme.surface, width: 1.5);
    final avatars = [
      for (final user in users)
        SmartAvatar(
          imageUrl: user.getAvatarUrl(size: 48),
          radius: size / 2,
          fallbackText: user.username,
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          border: ring,
        ),
      for (var i = 0; i < groupCount; i++)
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.secondaryContainer,
            border: ring,
          ),
          child: Icon(
            Symbols.group_rounded,
            size: 14,
            color: scheme.onSecondaryContainer,
          ),
        ),
    ];
    if (avatars.isEmpty) return const SizedBox.shrink();
    final step = size - 8;
    return ExcludeSemantics(
      child: SizedBox(
        width: size + (avatars.length - 1) * step,
        height: size,
        child: Stack(
          children: [
            for (var i = 0; i < avatars.length; i++)
              PositionedDirectional(
                start: i * step,
                width: size,
                height: size,
                child: avatars[i],
              ),
          ],
        ),
      ),
    );
  }
}
