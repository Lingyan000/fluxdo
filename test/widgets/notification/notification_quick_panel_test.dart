import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/notification/notification_quick_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingRecentNotifications extends RecentNotificationsNotifier {
  _CountingRecentNotifications(this.onBuild);

  final Future<List<DiscourseNotification>> Function() onBuild;

  @override
  Future<List<DiscourseNotification>> build() => onBuild();
}

void main() {
  testWidgets('首次打开通知面板只触发一次 GET /notifications，二次打开正常刷新', (tester) async {
    SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
    final prefs = await SharedPreferences.getInstance();
    addTearDown(() => NotificationQuickPanel.visible.value = false);

    var buildCount = 0;
    Completer<List<DiscourseNotification>>? gate =
        Completer<List<DiscourseNotification>>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recentNotificationsProvider.overrideWith(
            () => _CountingRecentNotifications(() {
              buildCount++;
              final currentGate = gate;
              if (currentGate != null && !currentGate.isCompleted) {
                return currentGate.future;
              }
              return Future.value(const []);
            }),
          ),
          systemUserAvatarTemplateProvider.overrideWith((ref) async => null),
          siteNotificationTypesProvider.overrideWith((ref) async => const {}),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(body: Stack(children: [SidebarNotificationPanel()])),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(buildCount, 0);

    // 首次打开面板：首帧 ref.watch 触发加载，microtask 不得重复 invalidate 造成双发。
    NotificationQuickPanel.visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(buildCount, 1);

    gate.complete(const []);
    gate = null;
    await tester.pumpAndSettle();
    expect(buildCount, 1);

    // 关闭后再次打开（同一会话已有缓存）：应正常触发一次刷新。
    NotificationQuickPanel.visible.value = false;
    await tester.pumpAndSettle();
    expect(buildCount, 1);

    NotificationQuickPanel.visible.value = true;
    await tester.pumpAndSettle();
    expect(buildCount, 2);

    NotificationQuickPanel.visible.value = false;
    await tester.pumpAndSettle();
  });
}
