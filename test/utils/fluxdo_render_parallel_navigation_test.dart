import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UserCardService extends Fake implements DiscourseService {
  final requests = <(String, int?)>[];

  @override
  Future<User> getUserCard(
    String username, {
    int? includePostCountFor,
    bool isSilent = false,
  }) async {
    requests.add((username, includePostCountFor));
    return User(id: 1, username: username, trustLevel: 0);
  }
}

Future<void> _prewarmPost(WidgetTester tester, List<BlockNode> nodes) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: FluxdoRender(cookedHtml: '<p>上一楼的正文</p>')),
    ),
  );
  final next = ParagraphWarmup.warmParagraphs(
    nodes: nodes,
    ctx: ParagraphWarmupProbe.snapshot()!,
    context: tester.element(find.byType(FluxdoRender)),
    totalImagesInPost: 0,
    mentionTapHandler: FluxdoRenderCallbacks.handlePrewarmedMentionTap,
    budgetMicros: const Duration(seconds: 1).inMicroseconds,
  );
  expect(next, -1);
}

void main() {
  testWidgets('正文站内链接压入当前平行视界栈', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedMessageProvider.notifier).select(topicId: 1);
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'parallel_link_test',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EmbeddedStackScope(
            stackProvider: selectedMessageProvider,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => callbacks.linkHandler(
                  context,
                  'https://linux.do/t/topic/42/7',
                ),
                child: const Text('打开站内链接'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开站内链接'));
    await tester.pump();

    final state = container.read(selectedMessageProvider);
    expect(state.stack, hasLength(2));
    expect(state.topicId, 42);
    expect(state.scrollToPostNumber, 7);
    expect(container.read(selectedTopicProvider).hasSelection, isFalse);
  });

  testWidgets('master 预览里的正文链接替换右栏而不继续叠层', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedTopicProvider.notifier).select(topicId: 1);
    container.read(selectedTopicProvider.notifier)
      ..pushProfile('alice')
      ..push(topicId: 2);
    final callbacks = FluxdoRenderCallbacks.generic(
      heroTagNamespace: 'parallel_truncate_test',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EmbeddedStackScope(
            stackProvider: selectedTopicProvider,
            truncateOnPush: true,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => callbacks.linkHandler(
                  context,
                  'https://linux.do/t/topic/99',
                ),
                child: const Text('替换右栏'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('替换右栏'));
    await tester.pump();

    final state = container.read(selectedTopicProvider);
    expect(state.stack, hasLength(3));
    expect(state.stack[0].topicId, 1);
    expect(state.stack[1].username, 'alice');
    expect(state.stack[2].topicId, 99);
  });

  for (final desktop in [true, false]) {
    final scene = desktop ? '预热过的桌面帖子' : '带状态表情的移动端聊天';
    testWidgets('$scene 中点击 @提及先显示用户卡片，从卡片进入当前分栏的资料页', (tester) async {
      PlatformUtils.debugDesktopOverride = desktop;
      addTearDown(() => PlatformUtils.debugDesktopOverride = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final service = _UserCardService();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          discourseServiceProvider.overrideWithValue(service),
          currentUserProvider.overrideWithBuild((_, _) => null),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(selectedFollowingFeedProvider.notifier)
          .select(topicId: 42);

      final status = desktop
          ? ''
          : '<img class="emoji mention-status" alt=":wave:">';
      final html =
          '<p>谢谢 <a class="mention" href="/u/alice">@Alice$status</a> 的帮助</p>';
      final nodes = ParagraphParser().parse(html);
      final callbacks = desktop
          ? FluxdoRenderCallbacks.forPost(
              post: Post.fromJson({'id': 1, 'post_number': 3, 'cooked': html}),
              topicId: 42,
            )
          : FluxdoRenderCallbacks.generic(heroTagNamespace: 'chat_mention');
      if (desktop) await _prewarmPost(tester, nodes);
      final missesBeforeMount = FlattenCache.misses;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              home: EmbeddedStackScope(
                stackProvider: selectedFollowingFeedProvider,
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.centerLeft,
                    child: callbacks.render(
                      cookedHtml: html,
                      parsedNodes: nodes,
                      selectionEnabled: desktop,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (desktop) expect(FlattenCache.misses, missesBeforeMount);

      final range = find.textRange.ofSubstring('@Alice').evaluate().single;
      final box = range.renderObject
          .getBoxesForSelection(
            TextSelection(
              baseOffset: range.textRange.start,
              extentOffset: range.textRange.end,
            ),
          )
          .single;
      final position = range.renderObject.localToGlobal(box.toRect().center);
      await tester.tapAt(
        position,
        kind: desktop ? PointerDeviceKind.mouse : PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();

      expect(service.requests, [('alice', desktop ? 42 : null)]);
      expect(container.read(selectedFollowingFeedProvider).stack, hasLength(1));
      final viewProfile = find.text(S.current.userCard_viewProfile);
      expect(viewProfile, findsOneWidget);
      if (desktop) {
        final card = find.ancestor(
          of: viewProfile,
          matching: find.byType(SingleChildScrollView),
        );
        expect(
          tester.getTopLeft(card).dx - position.dx,
          inExclusiveRange(0, 20),
        );
      }

      await tester.tap(viewProfile);
      await tester.pumpAndSettle();
      final state = container.read(selectedFollowingFeedProvider);
      expect(state.stack, hasLength(2));
      expect(state.username, 'alice');
      expect(container.read(selectedTopicProvider).hasSelection, isFalse);
    });
  }
}
