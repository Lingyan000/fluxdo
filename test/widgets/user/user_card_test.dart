import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/user/user_card.dart';

class _CurrentUser extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _Service implements DiscourseService {
  int requests = 0;

  @override
  Future<User> getUserCard(
    String username, {
    int? includePostCountFor,
    bool isSilent = false,
  }) async {
    requests++;
    return User(id: 1, username: username, trustLevel: 0, avatarTemplate: '');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _card = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_UserCardContent',
);

Future<_Service> _openCard(
  WidgetTester tester, {
  required Size size,
  Offset anchor = const Offset(20, 100),
  bool linked = true,
  bool alignRight = false,
  ScrollController? scrollController,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final link = LayerLink();
  final anchorKey = GlobalKey();
  final service = _Service();
  Widget body = SizedBox(
    height: scrollController == null ? size.height : 1600,
    child: Stack(
      children: [
        Positioned(
          left: alignRight ? null : anchor.dx,
          right: alignRight ? 20 : null,
          top: anchor.dy,
          child: Builder(
            builder: (context) => CompositedTransformTarget(
              link: link,
              child: SizedBox(
                key: anchorKey,
                width: 40,
                height: 40,
                child: GestureDetector(
                  onTap: () {
                    final box =
                        anchorKey.currentContext!.findRenderObject()!
                            as RenderBox;
                    showUserCard(
                      context: context,
                      anchorRect: box.localToGlobal(Offset.zero) & box.size,
                      layerLink: linked ? link : null,
                      username: 'alice',
                    );
                  },
                  child: const ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  if (scrollController != null) {
    body = SingleChildScrollView(controller: scrollController, child: body);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_CurrentUser.new),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(body: body),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(anchorKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  expect(tester.takeException(), isNull);
  expect(_card, findsOneWidget);
  return service;
}

void _expectInside(WidgetTester tester, Size size) {
  final rect = tester.getRect(_card);
  expect(rect.left, greaterThanOrEqualTo(12));
  expect(rect.right, lessThanOrEqualTo(size.width - 12));
  // 卡片顶部额外留出外凸头像的高度。
  expect(rect.top, greaterThanOrEqualTo(36));
  expect(rect.bottom, lessThanOrEqualTo(size.height - 12));
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = true);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  for (final linked in [true, false]) {
    for (final (size, anchor) in [
      (const Size(800, 700), const Offset(20, 100)),
      (const Size(800, 700), const Offset(740, 600)),
      (const Size(480, 700), const Offset(20, 100)),
      (const Size(480, 700), const Offset(220, 600)),
      (const Size(320, 700), const Offset(20, 100)),
      (const Size(480, 240), const Offset(20, 100)),
    ]) {
      testWidgets('桌面用户卡片限制在窗口内 $size/$anchor 跟随=$linked', (tester) async {
        await _openCard(tester, size: size, anchor: anchor, linked: linked);
        _expectInside(tester, size);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('打开后缩小窗口重新约束卡片，且不重复加载用户', (tester) async {
    final service = await _openCard(tester, size: const Size(800, 700));
    tester.view.physicalSize = const Size(320, 240);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    _expectInside(tester, const Size(320, 240));
    expect(service.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窗口缩放导致头像换位时，卡片仍限制在窗口内', (tester) async {
    await _openCard(tester, size: const Size(800, 700), alignRight: true);
    tester.view.physicalSize = const Size(320, 240);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    _expectInside(tester, const Size(320, 240));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄窗口卡片继续跟随头像滚动，并可点击外部关闭', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _openCard(
      tester,
      size: const Size(480, 700),
      anchor: const Offset(20, 220),
      scrollController: controller,
    );
    final before = tester.getRect(_card);
    controller.jumpTo(30);
    await tester.pump();
    final after = tester.getRect(_card);
    expect(after.top, closeTo(before.top - 30, 0.01));
    expect(after.left, before.left);
    // 卡内点击不关闭，卡外点击关闭。
    await tester.tapAt(after.center);
    await tester.pump();
    expect(_card, findsOneWidget);
    await tester.tapAt(const Offset(470, 680));
    await tester.pump();
    expect(_card, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
