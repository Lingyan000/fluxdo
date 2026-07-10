import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/discourse_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/topic/topic_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _titlePrefix = 'Scaled';

Topic _topic() => Topic(
  id: 1,
  title: '$_titlePrefix :smile:',
  slug: 'scaled-topic',
  postsCount: 5,
  replyCount: 4,
  views: 10,
  likeCount: 0,
  categoryId: '0',
  closed: true,
);

Future<void> _pumpCard(WidgetTester tester, Widget card) async {
  SharedPreferences.setMockInitialValues({'pref_topic_title_font_scale': 2.0});
  final preferences = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        categoryMapProvider.overrideWithValue(
          const AsyncData<Map<int, Category>>({}),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          textTheme: const TextTheme(
            titleMedium: TextStyle(fontSize: 20),
            labelMedium: TextStyle(fontSize: 12),
            labelSmall: TextStyle(fontSize: 8),
          ),
        ),
        home: Scaffold(
          body: Center(child: SizedBox(width: 800, child: card)),
        ),
      ),
    ),
  );
  await tester.pump();
}

Text _findTitleText(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .singleWhere(
        (widget) =>
            widget.textSpan?.toPlainText().contains(_titlePrefix) ?? false,
      );
}

Image _findEmojiImage(Text title) {
  final root = title.textSpan! as TextSpan;
  final emojiSpan = root.children!.whereType<WidgetSpan>().singleWhere((span) {
    final child = span.child;
    return child is Padding && child.child is Image;
  });
  return (emojiSpan.child as Padding).child! as Image;
}

void main() {
  testWidgets('TopicCard scales only title text and emoji', (tester) async {
    await _pumpCard(tester, TopicCard(topic: _topic()));

    final title = _findTitleText(tester);
    final emoji = _findEmojiImage(title);
    final replyCount = tester.widget<Text>(find.text('4'));
    final lockIcon = tester.widget<Icon>(find.byIcon(Symbols.lock_rounded));

    expect(title.textSpan!.style?.fontSize, 40);
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(emoji.width, 48);
    expect(replyCount.style?.fontSize, 8);
    expect(lockIcon.size, 16);
  });

  testWidgets('CompactTopicCard scales title and keeps one-line ellipsis', (
    tester,
  ) async {
    await _pumpCard(tester, CompactTopicCard(topic: _topic()));

    final title = _findTitleText(tester);
    final emoji = _findEmojiImage(title);
    final lockIcon = tester.widget<Icon>(find.byIcon(Symbols.lock_rounded));

    expect(title.textSpan!.style?.fontSize, 24);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(emoji.width, closeTo(28.8, 0.001));
    expect(lockIcon.size, 12);
  });
}
