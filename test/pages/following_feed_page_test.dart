import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/following_feed.dart';
import 'package:fluxdo/pages/following_feed_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/following_feed_provider.dart';
import 'package:fluxdo/providers/following_feed_migration_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';

class _User extends CurrentUserNotifier {
  @override
  Future<User?> build() async => User(id: 1, username: 'alice', trustLevel: 1);
}

void main() {
  testWidgets('窄屏可进入动态、查看旧名单并确认引导', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'seeking_config': '{"users":["bob"]}',
    });
    final prefs = await SharedPreferences.getInstance();
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_User.new),
        followingFeedProvider('alice').overrideWith(
          (ref) => FollowingFeedNotifier((_) async {
            requests++;
            return const FollowingFeedResponse(posts: [], hasMore: false);
          })..refresh(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const FollowingFeedPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('暂无关注动态'), findsOneWidget);
    await tester.tap(find.text('追觅已升级为关注动态'));
    await tester.pumpAndSettle();
    expect(find.text('bob'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(container.read(followingFeedMigrationProvider).showGuide, false);
    expect(find.text('暂无关注动态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('真实 extras 分页响应：滚到底部自动请求并追加第二页', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cursors = <String?>[];
    FollowingFeedResponse response(int start, int count, bool hasMore) =>
        FollowingFeedResponse.fromJson({
          '__rest_serializer': '1',
          'extras': {'has_more': hasMore},
          'posts': [
            for (var id = start; id > start - count; id--)
              {
                'id': id,
                'topic_id': id,
                'post_number': 1,
                'created_at':
                    '2026-11-17T00:00:${id.toString().padLeft(2, '0')}.123456Z',
                'user': {'id': 2, 'username': 'bob', 'avatar_template': ''},
                'topic': {'id': id, 'title': '动态 $id'},
              },
          ],
        });
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_User.new),
        followingFeedProvider('alice').overrideWith(
          (ref) => FollowingFeedNotifier((before) async {
            cursors.add(before);
            return before == null
                ? response(30, 20, true)
                : response(10, 10, false);
          })..refresh(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const FollowingFeedPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cursors, [null]);
    for (var i = 0; i < 15 && cursors.length == 1; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -650));
      await tester.pumpAndSettle();
    }
    expect(cursors, [null, '2026-11-17T00:00:11.123456Z']);
    final state = container.read(followingFeedProvider('alice'));
    expect(state.posts, hasLength(30));
    expect(state.hasMore, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
