import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/chat/chat_models.dart';
import 'package:fluxdo/pages/chat/chat_page.dart';
import 'package:fluxdo/widgets/chat/chat_conversation_tabs.dart';

Widget _host({required int privateCount, required int groupCount}) {
  return TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: Scaffold(
        body: ChatConversationTabs(
          id: 'test',
          privateCount: privateCount,
          groupCount: groupCount,
          privateChild: const Center(child: Text('私聊内容')),
          groupChild: const Center(child: Text('群聊内容')),
        ),
      ),
    ),
  );
}

void main() {
  test('会话分类保留 1:1 DM、群组 DM 和收藏的公开频道', () {
    const channels = [
      ChatChannel(id: 1, chatableType: 'DirectMessage'),
      ChatChannel(id: 2, chatableType: 'DirectMessageChannel', isGroupDm: true),
      ChatChannel(id: 3, chatableType: 'Category'),
    ];

    final result = partitionChatChannels(channels);

    expect(result.privateChats.map((channel) => channel.id), [1]);
    expect(result.groupChats.map((channel) => channel.id), [2, 3]);
    expect(
      {
        ...result.privateChats,
        ...result.groupChats,
      }.map((channel) => channel.id),
      containsAll([1, 2, 3]),
    );
  });

  testWidgets('私聊 / 群聊子 Tab 展示数量并可切换内容', (tester) async {
    await tester.pumpWidget(_host(privateCount: 2, groupCount: 1));
    await tester.pumpAndSettle();

    expect(find.text('私聊'), findsOneWidget);
    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('私聊内容'), findsOneWidget);
    expect(find.text('群聊内容'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-test-group-tab')));
    await tester.pumpAndSettle();

    expect(find.text('私聊内容'), findsNothing);
    expect(find.text('群聊内容'), findsOneWidget);
  });

  testWidgets('仅有群聊时默认打开有内容的群聊子 Tab', (tester) async {
    await tester.pumpWidget(_host(privateCount: 0, groupCount: 3));
    await tester.pumpAndSettle();

    expect(find.text('私聊内容'), findsNothing);
    expect(find.text('群聊内容'), findsOneWidget);
  });
}
