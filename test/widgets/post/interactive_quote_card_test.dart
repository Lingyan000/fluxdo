import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';
import 'package:fluxdo/utils/quote_excerpt_highlight.dart';
import 'package:fluxdo/widgets/post/quote_navigation_scope.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:html/parser.dart' as html;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Posts extends Fake implements DiscourseService {
  final calls = <(int, int)>[];
  final pending = <Completer<Post>>[];

  @override
  Future<Post> getPostByNumber(int topicId, int postNumber) {
    calls.add((topicId, postNumber));
    final request = Completer<Post>();
    pending.add(request);
    return request.future;
  }
}

Post _post(String cooked, {int number = 8, String username = 'author'}) =>
    Post.fromJson({
      'id': number,
      'post_number': number,
      'username': username,
      'cooked': cooked,
    });

String _quote([String attrs = '']) =>
    '<aside class="quote" data-post="7" $attrs>'
    '<blockquote><p>one sentence</p></blockquote></aside>';

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Posts posts,
  String cooked, {
  ValueChanged<int>? jump,
  List<String> blocked = const [],
  bool screenshot = false,
}) async {
  SharedPreferences.setMockInitialValues({'pref_blocked_usernames': blocked});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(posts),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: EmbeddedStackScope(
              stackProvider: selectedTopicProvider,
              child: QuoteNavigationScope(
                topicId: 100,
                onJump: jump ?? (_) => fail('不应跳转'),
                child: FluxdoRenderCallbacks.forPost(
                  post: _post(cooked),
                  topicId: 100,
                ).render(cookedHtml: cooked, screenshotMode: screenshot),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(
    tester.element(find.byType(FluxdoRender).first),
    listen: false,
  );
}

void main() {
  testWidgets('展开在卡内等待，收起不丢请求；重开高亮原句，只有楼层会跳转', (tester) async {
    final posts = _Posts();
    final jumps = <int>[];
    await _show(tester, posts, _quote(), jump: jumps.add);
    expect(posts.calls, isEmpty);
    await tester.tap(find.byTooltip(t.post_quoteExpand));
    await tester.pump();
    expect(posts.calls, [(100, 7)]);
    await tester.tap(find.byTooltip(t.post_quoteCollapse));
    await tester.pump();
    posts.pending.single.complete(
      _post('<p>before</p><p>one <b>sentence</b></p><p>after</p>', number: 7),
    );
    await tester.pump();
    expect(find.byType(FluxdoRender), findsOneWidget);
    await tester.tap(find.byTooltip(t.post_quoteExpand));
    await tester.pumpAndSettle();
    final source = tester.widget<FluxdoRender>(find.byType(FluxdoRender).last);
    expect(source.cookedHtml, contains('<p>before</p>'));
    expect(
      html
          .parseFragment(source.cookedHtml)
          .querySelectorAll('span[style]')
          .map((span) => span.text)
          .join(),
      'one sentence',
    );
    expect(find.byType(SelectionScope), findsNWidgets(2));
    expect(jumps, isEmpty);
    await tester.tap(find.text('#7'));
    expect(jumps, [7]);
    expect(posts.calls, hasLength(1));
    AuthSession().advance();
    await tester.pump();
    expect(find.byType(FluxdoRender), findsOneWidget);
    expect(find.byTooltip(t.post_quoteExpand), findsOneWidget);
  });

  testWidgets('跨话题用面板路由；全文引用只跳转，失效引用和截图不拉取', (tester) async {
    final posts = _Posts();
    final container = await _show(
      tester,
      posts,
      _quote('data-topic="101" data-full="true"'),
    );
    expect(find.byTooltip(t.post_quoteExpand), findsNothing);
    await tester.tap(find.text('#7'));
    final entry = container.read(selectedTopicProvider).stack.single;
    expect((entry.topicId, entry.scrollToPostNumber), (101, 7));
    await _show(
      tester,
      posts,
      _quote().replaceFirst(
        'class="quote"',
        'class="quote quote-post-not-found"',
      ),
    );
    expect(find.byTooltip(t.post_quoteExpand), findsNothing);
    expect(
      tester.widget<RenderQuoteCard>(find.byType(RenderQuoteCard)).onOpen,
      isNull,
    );
    await _show(tester, posts, _quote(), screenshot: true);
    expect(find.byTooltip(t.post_quoteExpand), findsNothing);
    expect(posts.calls, isEmpty);
  });

  for (final status in [403, 404, 503]) {
    testWidgets('$status 保留摘录，只有临时错误能重试', (tester) async {
      final posts = _Posts();
      await _show(tester, posts, _quote());
      await tester.tap(find.byTooltip(t.post_quoteExpand));
      await tester.pump();
      final options = RequestOptions(path: '/posts/by_number/100/7');
      posts.pending.single.completeError(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: status),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InlineSpanText), findsOneWidget);
      expect(
        find.text(
          status == 403
              ? t.error_forbiddenAccess
              : status == 404
              ? t.error_notFoundOrDeleted
              : t.error_loadFailed,
        ),
        findsOneWidget,
      );
      if (status == 503) {
        await tester.tap(find.text(t.common_retry));
        await tester.pump();
        posts.pending.last.complete(_post('<p>recovered</p>', number: 7));
        await tester.pumpAndSettle();
        expect(find.byType(FluxdoRender), findsNWidgets(2));
        expect(posts.calls, hasLength(2));
      } else {
        expect(find.text(t.common_retry), findsNothing);
        expect(
          tester.widget<RenderQuoteCard>(find.byType(RenderQuoteCard)).onOpen,
          isNull,
        );
      }
    });
  }

  testWidgets('本地拉黑按用户名隐藏摘录；话题引用取回作者后也不会显示原帖', (tester) async {
    final posts = _Posts();
    await _show(
      tester,
      posts,
      _quote('data-username="Author"'),
      blocked: ['author'],
    );
    expect(find.text(t.post_quoteBlocked), findsOneWidget);
    expect(find.byTooltip(t.post_quoteExpand), findsNothing);
    await _show(tester, posts, _quote('data-topic="101"'), blocked: ['author']);
    await tester.tap(find.byTooltip(t.post_quoteExpand));
    await tester.pump();
    posts.pending.single.complete(_post('<p>not shown</p>', number: 7));
    await tester.pumpAndSettle();
    expect(find.text(t.post_quoteBlocked), findsOneWidget);
    expect(find.byType(InlineSpanText), findsNothing);
  });

  test('高亮保留富文本链接和转义；重复、空摘录或编辑过的原句不猜位置', () {
    String highlight(String cooked, String excerpt) => highlightQuoteExcerpt(
      cooked,
      excerpt,
      foreground: const Color(0xff101010),
      background: const Color(0xffeeeeee),
    );
    const cooked =
        '<p>before <a href="/example"><b>A&amp;B</b>\n  &lt;C&gt;</a> after</p>';
    final doc = html.parseFragment(highlight(cooked, 'A&B <C>'));
    expect(doc.querySelector('a')!.attributes['href'], '/example');
    expect(doc.querySelector('b > span')!.text, 'A&B');
    expect(doc.querySelectorAll('a span').last.text.trim(), '<C>');
    expect(highlight(cooked, 'changed'), cooked);
    expect(highlight(cooked, ''), cooked);
    expect(highlight('<p>aaaa</p>', 'aaa'), '<p>aaaa</p>');
    expect(
      html
          .parseFragment(highlight('<p>第一行</p><p>下一行继续</p>', '第一行\n 下一行…'))
          .querySelectorAll('span')
          .map((span) => span.text)
          .join(),
      '第一行下一行',
    );
  });
}
