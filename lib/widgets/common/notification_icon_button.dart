import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/message_bus/notification_providers.dart';
import '../notification/notification_quick_panel.dart';

class NotificationIconButton extends ConsumerWidget {
  const NotificationIconButton({super.key, this.compact = false});

  /// 紧凑模式：只收缩触控目标/密度，glyph 保持默认 24
  /// （缩 glyph 会与同行其他图标失调，显小）
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(
      notificationCountStateProvider.select((s) => s.allUnread),
    );
    return IconButton(
      onPressed: () {
        NotificationQuickPanel.show(context);
      },
      visualDensity: compact ? VisualDensity.compact : null,
      style: compact
          ? IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      icon: Badge(
        isLabelVisible: unreadCount > 0,
        label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
        child: const Icon(Symbols.notifications_rounded),
      ),
      tooltip: context.l10n.common_notification,
    );
  }
}
