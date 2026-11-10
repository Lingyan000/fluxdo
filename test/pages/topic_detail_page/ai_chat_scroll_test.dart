import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/ai_chat_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/common/positioned_stream_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Chat extends TopicAiChatNotifier {
  _Chat(SharedPreferences prefs, List<AiChatMessage> messages)
    : super(
        chatService: AiChatService(),
        storageService: AiChatStorageService(prefs),
        topicId: 1,
      ) {
    state = TopicAiChatState(messages: messages, currentSessionId: 'first');
  }

  void replace(List<AiChatMessage> messages, {String session = 'first'}) {
    state = TopicAiChatState(messages: messages, currentSessionId: session);
  }
}

AiChatMessage _message(int index, {int paragraphs = 3}) => AiChatMessage(
  id: '$index',
  role: ChatRole.assistant,
  createdAt: DateTime(2026),
  content: List.generate(
    paragraphs,
    (line) => 'Message $index paragraph $line. A reply with variable height.',
  ).join('\n\n'),
);

Future<void> _frames(WidgetTester tester, [int count = 12]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<_Chat> _pump(WidgetTester tester, List<AiChatMessage> messages) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.runAsync(() async {
    if (!PreloadedDataService().isLoaded) {
      await PreloadedDataService().hydrateFromHtml(
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
          'currentUser': {'id': 1, 'username': 'tester'},
          'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
          'site': {'categories': [], 'top_tags': []},
        })}</script>',
      );
      await DiscourseCookService().ensureInitialized();
    }
  });
  final chat = _Chat(prefs, messages);
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiSharedPreferencesProvider.overrideWithValue(prefs),
        sharedPreferencesProvider.overrideWithValue(prefs),
        topicAiChatProvider(1).overrideWith((ref) => chat),
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
          home: const AiChatPage(topicId: 1, embedded: true),
        ),
      ),
    ),
  );
  await _frames(tester);
  return chat;
}

PositionedStreamList _list(WidgetTester tester) =>
    tester.widget(find.byType(PositionedStreamList));

void main() {
  testWidgets('短会话靠输入框排列，流式增长到长会话持续贴底', (tester) async {
    final chat = await _pump(tester, [_message(1, paragraphs: 1)]);
    final viewport = tester.getRect(find.byType(PositionedStreamList));
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('bottom-inset'))).dy,
      closeTo(viewport.bottom, 1),
    );
    for (var paragraphs = 2; paragraphs < 18; paragraphs++) {
      chat.replace([_message(1, paragraphs: paragraphs)]);
      await _frames(tester, 2);
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('bottom-inset'))).dy,
        closeTo(viewport.bottom, 1),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('首屏加载历史位于最新回复，流式增高逐帧贴底', (tester) async {
    final messages = List.generate(35, _message);
    final chat = await _pump(tester, messages);
    final scroll = _list(tester).scrollController;
    expect(scroll.position.extentBefore, lessThan(1));
    for (var chunk = 4; chunk <= 16; chunk++) {
      chat.replace([
        ...messages.take(34),
        _message(
          34,
          paragraphs: chunk,
        ).copyWith(status: MessageStatus.streaming),
      ]);
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.position.extentBefore, lessThan(1));
    }
    chat.replace([...messages, _message(35)]);
    await tester.pump();
    expect(scroll.position.extentBefore, lessThan(1));
    expect(find.byKey(const ValueKey('message-35')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑阅读历史时流式更新和新消息保持阅读位置', (tester) async {
    final messages = List.generate(35, _message);
    final chat = await _pump(tester, messages);
    await tester.drag(find.byType(PositionedStreamList), const Offset(0, 580));
    await _frames(tester);
    final list = _list(tester);
    final anchor = list.listController.anchor!;
    final key = list.itemKeys[anchor.index];
    final finder = find.byKey(ValueKey(key));
    final before = tester.getTopLeft(finder).dy;
    expect(list.scrollController.position.extentBefore, greaterThan(200));
    chat.replace([
      ...messages.take(34),
      _message(34, paragraphs: 25),
      _message(35),
    ]);
    await tester.pump();
    expect(tester.getTopLeft(finder).dy, closeTo(before, 1));
    await _frames(tester);
    expect(tester.getTopLeft(finder).dy, closeTo(before, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换会话重新定位到最新消息，清空后再次发送正常', (tester) async {
    final chat = await _pump(tester, List.generate(35, _message));
    await tester.drag(find.byType(PositionedStreamList), const Offset(0, 480));
    await _frames(tester);
    chat.replace(
      List.generate(70, (i) => _message(i + 100)),
      session: 'second',
    );
    await _frames(tester);
    expect(_list(tester).scrollController.position.extentBefore, lessThan(1));
    expect(find.byKey(const ValueKey('message-169')), findsOneWidget);
    chat.replace([], session: 'empty');
    await _frames(tester);
    expect(find.byType(PositionedStreamList), findsNothing);
    chat.replace([_message(300, paragraphs: 30)], session: 'third');
    await _frames(tester);
    expect(_list(tester).scrollController.position.extentBefore, lessThan(1));
    expect(tester.takeException(), isNull);
  });
}
