import 'package:material_ui/material_ui.dart';

import '../common/skeleton.dart';
import '../user/activity_card_layout.dart';

/// 通知列表骨架屏（快捷面板、通知弹窗），与 NotificationItem 同构
class NotificationListSkeleton extends StatelessWidget {
  const NotificationListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: 10,
        itemBuilder: (context, index) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: _NotificationContentSkeleton(),
        ),
      ),
    );
  }
}

/// 历史通知页骨架，与 NotificationCard 同构
class NotificationCardListSkeleton extends StatelessWidget {
  const NotificationCardListSkeleton({super.key, this.itemCount = 8});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ActivityCardList(
        builder: (context, padding) => ListView.builder(
          padding: padding,
          itemCount: itemCount,
          itemBuilder: (context, index) => ActivityCardFrame(
            position: (index: index, count: itemCount),
            child: const _NotificationContentSkeleton(),
          ),
        ),
      ),
    );
  }
}

/// 与 NotificationContent 同构：头像、动作行与时间、话题行
class _NotificationContentSkeleton extends StatelessWidget {
  const _NotificationContentSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final baseFontSize = theme.textTheme.bodyMedium!.fontSize!;
    final metaHeight = scaler.scale(baseFontSize - 1) * 1.4;
    final titleHeight = scaler.scale(baseFontSize) * 1.45;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonCircle(size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(child: SkeletonBox(width: 168, height: metaHeight)),
                  const Spacer(),
                  SkeletonBox(width: 40, height: metaHeight),
                ],
              ),
              const SizedBox(height: 4),
              SkeletonBox(width: double.infinity, height: titleHeight),
            ],
          ),
        ),
      ],
    );
  }
}
