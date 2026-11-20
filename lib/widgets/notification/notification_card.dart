import 'package:material_ui/material_ui.dart';

import '../../models/notification.dart';
import '../user/activity_card_layout.dart';
import 'notification_item.dart';

/// 历史通知页的通知卡，内容与面板列表项一致，外壳沿用活动卡
class NotificationCard extends StatelessWidget {
  const NotificationCard({
    super.key,
    required this.notification,
    required this.position,
    required this.onTap,
    this.systemAvatarTemplate,
  });

  final DiscourseNotification notification;
  final ({int index, int count}) position;
  final VoidCallback onTap;
  final String? systemAvatarTemplate;

  @override
  Widget build(BuildContext context) {
    return ActivityCardFrame(
      position: position,
      highlighted: !notification.read,
      onTap: onTap,
      child: NotificationContent(
        notification: notification,
        systemAvatarTemplate: systemAvatarTemplate,
      ),
    );
  }
}
