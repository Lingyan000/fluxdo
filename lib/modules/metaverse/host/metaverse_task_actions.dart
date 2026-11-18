import 'dart:convert';

import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../../../services/local_notification_service.dart';
import '../plugin/metaverse_plugin_manifest.dart';
import '../plugin/metaverse_task.dart';
import 'metaverse_task_store.dart';

class MetaverseTaskActions {
  MetaverseTaskActions(
    this.store,
    this.manifest,
    this.account, {
    required this.changed,
    required this.checkActive,
    LocalNotificationService? notifications,
  }) : notifications = notifications ?? LocalNotificationService();

  final MetaverseTaskStore store;
  final MetaversePluginManifest manifest;
  final int account;
  final void Function() checkActive;
  final Future<void> Function() changed;
  final LocalNotificationService notifications;

  Future<Object?> call(String method, Map<String, Object?> params) async {
    checkActive();
    final plugin = manifest.id;
    switch (method) {
      case 'tasks.schedule':
        final schedule = MetaverseTaskSchedule.parse(params);
        if (!manifest.tasks.any((spec) => spec.id == schedule.id) ||
            (schedule.background && !manifest.capabilities.background)) {
          throw const MetaversePluginCallException('task_permission_denied');
        }
        store.schedule(
          account,
          plugin,
          schedule,
          background: schedule.background,
        );
        try {
          await changed();
        } catch (_) {
          store.cancel(account, plugin, schedule.id);
          rethrow;
        }
        return true;
      case 'tasks.cancel':
        final id = params['id'];
        if (id is! String || !manifest.tasks.any((task) => task.id == id)) {
          throw const MetaversePluginCallException('task_not_declared');
        }
        store.cancel(account, plugin, id);
        await changed();
        return null;
      case 'tasks.list':
        return store.tasks(account, plugin);
      case 'navigation.setBadge':
        final page = params['page'], count = params['count'];
        if (!manifest.requiredFeatures.contains('navigationBadge') ||
            page is! String ||
            manifest.page(page)?.navigation == null ||
            count is! int ||
            count < 0 ||
            count > 99999) {
          throw const MetaversePluginCallException('badge_invalid');
        }
        store.setBadge(account, plugin, page, count);
        await changed();
        return null;
      case 'notifications.requestPermission':
        final granted = await notifications.requestPluginPermission();
        checkActive();
        store.allowNotifications(account, plugin, granted);
        await changed();
        return granted;
      case 'notifications.isAllowed':
        return store.notificationsAllowed(account, plugin);
      case 'notifications.revoke':
        store.allowNotifications(account, plugin, false);
        final ids = store.notificationIds(plugin, account: account);
        store.forgetNotifications(plugin, account: account);
        for (final id in ids) {
          await notifications.cancelNotification(id);
        }
        await changed();
        return null;
      case 'notifications.cancel':
        final key = _text(params['key'], 64);
        final ids = store.notificationIds(plugin, account: account, key: key);
        store.forgetNotifications(plugin, account: account, key: key);
        for (final id in ids) {
          await notifications.cancelNotification(id);
        }
        return null;
      case 'notifications.show':
        if (!manifest.capabilities.notifications ||
            !store.notificationsAllowed(account, plugin)) {
          throw const MetaversePluginCallException(
            'notification_permission_denied',
          );
        }
        final key = _text(params['key'], 64),
            title = _text(params['title'], 100);
        final body = _text(params['body'], 500),
            page = _text(params['page'], 64);
        final args = params['params'] ?? const <String, Object?>{};
        if (manifest.page(page) == null ||
            args is! Map<String, Object?> ||
            utf8.encode(jsonEncode(args)).length > 2048) {
          throw const MetaversePluginCallException(
            'notification_invalid_destination',
          );
        }
        final row = store.notification(
          account,
          plugin,
          key,
          page: page,
          params: args,
        );
        if (row['deliver'] != true) return false;
        final id = row['id'] as int;
        try {
          await notifications.showPlugin(
            id: id,
            pluginName: manifest.name,
            title: title,
            body: body,
          );
          checkActive();
          if (!store.notificationsAllowed(account, plugin) ||
              store.notificationTarget(id) == null) {
            throw const MetaversePluginCallException(
              'notification_permission_denied',
            );
          }
        } catch (_) {
          await notifications.cancelNotification(id);
          rethrow;
        }
        return true;
    }
    throw const MetaversePluginCallException('task_unavailable');
  }

  static String _text(Object? value, int limit) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > limit ||
        value.contains('\u0000')) {
      throw const MetaversePluginCallException('notification_invalid');
    }
    return value.trim();
  }
}
