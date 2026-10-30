import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/tag_notification_level.dart';
import '../../providers/tag_notification_provider.dart';
import '../../services/app_error_handler.dart';
import '../common/notification_level_button.dart';

class TagNotificationButton extends ConsumerWidget {
  const TagNotificationButton({super.key, required this.tagName});

  final String tagName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = tagNotificationLevelProvider(tagName);
    final notification = ref.watch(provider);
    final level = notification.value;

    return NotificationLevelButton(
      level: level?.value,
      label: level?.label,
      isLoading: notification.isLoading,
      errorTooltip: notification.hasError
          ? context.l10n.tag_notificationLoadFailed
          : null,
      onPressed: notification.hasError
          ? () => ref.invalidate(provider)
          : level == null
          ? null
          : () => _showSheet(context, ref, level),
    );
  }

  void _showSheet(
    BuildContext context,
    WidgetRef ref,
    TagNotificationLevel currentLevel,
  ) {
    showNotificationLevelSelectionSheet(
      context: context,
      currentLevel: currentLevel,
      options: [
        for (final level in TagNotificationLevel.values)
          NotificationLevelOption(
            value: level,
            icon: notificationLevelIcon(level.value),
            label: level.label,
            description: level.description,
          ),
      ],
      onSelected: (level) async {
        if (!context.mounted) return;
        try {
          await ref
              .read(tagNotificationLevelProvider(tagName).notifier)
              .setLevel(level);
        } on DioException catch (_) {
          // 操作失败的提示由 ErrorInterceptor 统一处理。
        } catch (error, stackTrace) {
          if (context.mounted) {
            AppErrorHandler.handleUnexpected(error, stackTrace);
          }
        }
      },
    );
  }
}
