import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_header_section.dart';
import 'package:fluxdo/widgets/post/post_replies_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post(int number) => Post(
  id: number,
  username: 'tester',
  avatarTemplate: '',
  cooked:
      '<p>Post $number</p><p>${List.filled(number % 4 + 1, 'Variable height reply.').join('<br>')}</p>',
  postNumber: number,
  postType: 1,
  updatedAt: DateTime(2026),
  createdAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
  replyToPostNumber: number > 3 ? 2 : 1,
);

class _Service extends Fake implements DiscourseService {
  final nextPage = Completer<PostStream>();
  @override
  Future<List<int>> getPostReplyIds(int postId) async =>
      List.generate(40, (index) => index + 2);
  @override
  Future<PostStream> getPosts(
    int topicId,
    List<int> postIds, {
    bool includeSuggested = false,
  }) async {
    if (postIds.first > 21) return nextPage.future;
    return PostStream(posts: postIds.map(_post).toList(), stream: postIds);
  }
}

class _CurrentUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

Future<_Service> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final service = _Service();
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_CurrentUser.new),
        discourseServiceProvider.overrideWithValue(service),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPostRepliesSheet(
                  context: context,
                  post: _post(1),
                  topicId: 1,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return service;
}

void main() {
  testWidgets('回复弹层保持拖拽扩展，并能从屏外子回复定位到原帖', (tester) async {
    await _pump(tester);
    final before = tester.getSize(find.byType(PositionedStreamList)).height;
    await tester.drag(find.byType(PositionedStreamList), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(PositionedStreamList)).height,
      greaterThan(before),
    );
    final list = tester.widget<PositionedStreamList>(
      find.byType(PositionedStreamList),
    );
    final jump = list.listController.jumpToIndex(
      list.itemKeys.indexOf('post-19'),
    );
    await tester.pumpAndSettle();
    await jump;
    expect(find.byKey(const ValueKey('post-2')), findsNothing);
    final header = tester.widget<PostHeaderSection>(
      find.byWidgetPredicate(
        (widget) => widget is PostHeaderSection && widget.post.postNumber == 19,
      ),
    );
    header.onReplyIndicatorTap!(2);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('post-2')), findsOneWidget);
    final viewport = tester.getRect(find.byType(PositionedStreamList));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('post-2'))).dy,
      closeTo(viewport.top, 1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('加载更多返回时保留响应时的阅读位置', (tester) async {
    final service = await _pump(tester);
    final list = tester.widget<PositionedStreamList>(
      find.byType(PositionedStreamList),
    );
    final jump = list.listController.jumpToIndex(
      list.itemKeys.indexOf('load-more'),
    );
    await tester.pumpAndSettle();
    await jump;
    await tester.tap(find.text(S.current.post_loadMoreReplies));
    await tester.pump();
    await tester.drag(find.byType(PositionedStreamList), const Offset(0, 100));
    await tester.pump(const Duration(milliseconds: 200));
    final anchor = list.listController.anchor!;
    final finder = find.byKey(ValueKey(list.itemKeys[anchor.index]));
    final before = tester.getTopLeft(finder);
    service.nextPage.complete(
      PostStream(posts: [for (var n = 22; n <= 41; n++) _post(n)], stream: []),
    );
    await tester.pump();
    expect(tester.getTopLeft(finder), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
