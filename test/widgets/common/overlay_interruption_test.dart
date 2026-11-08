import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/widgets/common/app_link_confirm_dialog.dart';
import 'package:fluxdo/widgets/common/image_lift_menu.dart';
import 'package:fluxdo/widgets/common/spotlight_overlay.dart';
import 'package:fluxdo/widgets/markdown_editor/emoji_popover.dart';
import 'package:fluxdo/widgets/notification/notification_quick_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding
    with DesktopScrollInteractionBinding {}

class _Notifications extends RecentNotificationsNotifier {
  @override
  Future<List<DiscourseNotification>> build() async => [];
}

void main() {
  _Binding();

  Future<(BuildContext, ScrollController)> home(
    WidgetTester tester, {
    GlobalKey? anchor,
    bool notifications = false,
  }) async {
    SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
    final prefs = await SharedPreferences.getInstance();
    final scroll = ScrollController(initialScrollOffset: 400);
    addTearDown(scroll.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recentNotificationsProvider.overrideWith(_Notifications.new),
          systemUserAvatarTemplateProvider.overrideWith((ref) async => null),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [RouteInteractionObserver()],
            scrollBehavior: const DesktopScrollInteractionBehavior(),
            home: Scaffold(
              body: Builder(
                builder: (value) {
                  context = value;
                  return Stack(
                    children: [
                      ListView.builder(
                        controller: scroll,
                        itemExtent: 60,
                        itemCount: 100,
                        itemBuilder: (_, i) => Text('row $i'),
                      ),
                      if (anchor != null)
                        Positioned(
                          left: 320,
                          top: 520,
                          child: SizedBox(
                            key: anchor,
                            width: 100,
                            height: 50,
                            child: const ColoredBox(color: Colors.blue),
                          ),
                        ),
                      if (notifications) const SidebarNotificationPanel(),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (context, scroll);
  }

  Future<void> swipe(
    WidgetTester tester,
    ScrollController scroll,
    Offset at,
  ) async {
    final before = scroll.offset;
    final gesture = await tester.startGesture(at);
    await gesture.moveBy(const Offset(3, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(4, -100));
    await tester.pump();
    expect(scroll.offset - before, greaterThan(60));
    await gesture.cancel();
  }

  testWidgets('表情弹层关闭同帧在原面板位置可以滚动', (tester) async {
    final controller = EmojiPopoverController();
    addTearDown(controller.dispose);
    final (context, scroll) = await home(tester, anchor: controller.anchorKey);
    controller.show(context, panel: const ColoredBox(color: Colors.red));
    await tester.pumpAndSettle();
    final at = tester.getCenter(
      find.byKey(const ValueKey('composer-emoji-popover')),
    );
    controller.hide();
    await swipe(tester, scroll, at);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('composer-emoji-popover')), findsNothing);
  });

  testWidgets('表情弹层关闭后同帧重开不继承旧动画结束回调', (tester) async {
    final controller = EmojiPopoverController();
    addTearDown(controller.dispose);
    final (context, _) = await home(tester, anchor: controller.anchorKey);
    var taps = 0;
    Widget panel() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => taps++,
      child: const ColoredBox(color: Colors.red),
    );
    controller.show(context, panel: panel());
    await tester.pumpAndSettle();
    controller.hide();
    controller.show(context, panel: panel());
    await tester.pumpAndSettle();
    expect(controller.isOpen, isTrue);
    await tester.tap(find.byKey(const ValueKey('composer-emoji-popover')));
    expect(taps, 1);
  });

  testWidgets('引导遮罩开始淡出就可滚动底层', (tester) async {
    final anchor = GlobalKey();
    final (context, scroll) = await home(tester, anchor: anchor);
    SpotlightOverlay.show(context, targetKey: anchor, message: '提示');
    addTearDown(SpotlightOverlay.dismiss);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tapAt(const Offset(600, 300));
    await swipe(tester, scroll, const Offset(600, 300));
    await tester.pumpAndSettle();
    expect(find.text('提示'), findsNothing);
  });

  testWidgets('程序关闭引导遮罩后同帧竖滑可达底层', (tester) async {
    final anchor = GlobalKey();
    final (context, scroll) = await home(tester, anchor: anchor);
    SpotlightOverlay.show(context, targetKey: anchor, message: '提示');
    addTearDown(SpotlightOverlay.dismiss);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    SpotlightOverlay.dismiss();
    await swipe(tester, scroll, const Offset(600, 300));
    await tester.pumpAndSettle();
    expect(find.text('提示'), findsNothing);
  });

  testWidgets('图片长按菜单关闭同帧竖滑不再被遮罩接走', (tester) async {
    final anchor = GlobalKey();
    final (_, scroll) = await home(tester, anchor: anchor);
    expect(
      ImageLiftMenu.show(
        context: anchor.currentContext!,
        previewBuilder: (_) => const ColoredBox(color: Colors.blue),
        actions: [ImageLiftAction(icon: Icons.copy, label: '复制', onTap: () {})],
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 80));
    await swipe(tester, scroll, const Offset(20, 300));
    await tester.pumpAndSettle();
    expect(ImageLiftMenu.activeSource.value, isNull);
  });

  testWidgets('应用链接横幅确认后立即交还输入且保留结果', (tester) async {
    final (context, scroll) = await home(tester);
    final result = showAppLinkConfirmDialog(
      context,
      'example://open',
      appName: '示例',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    expect(await result, isTrue);
    await swipe(tester, scroll, const Offset(400, 45));
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('侧边通知面板关闭立即放行原面板区域', (tester) async {
    final (context, scroll) = await home(tester, notifications: true);
    await NotificationQuickPanel.show(context);
    addTearDown(NotificationQuickPanel.dismiss);
    await tester.pumpAndSettle();
    expect(NotificationQuickPanel.isVisible, isTrue);
    NotificationQuickPanel.dismiss();
    await swipe(tester, scroll, const Offset(150, 300));
    await tester.pumpAndSettle();
    expect(NotificationQuickPanel.isVisible, isFalse);
  });
}
