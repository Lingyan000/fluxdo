import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_reply_session.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_quick_reply.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_draft_store.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/emoji_picker.dart';
import 'package:fluxdo/widgets/post/post_boost/boost_input.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpHost(WidgetTester tester, Widget home) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 840);
  tester.view.viewPadding = const FakeViewPadding(bottom: 24);
  tester.view.padding = const FakeViewPadding(bottom: 24);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        emojiGroupsProvider.overrideWith(
          (ref) => Stream.value({
            'smileys': [
              for (final name in ['smile', 'wave', 'heart'])
                Emoji(
                  name: name,
                  url: '/images/emoji/$name.png',
                  group: 'smileys',
                ),
            ],
          }),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: home,
        ),
      ),
    ),
  );
}

Future<void> _keyboardFrame(WidgetTester tester, double height) async {
  tester.view.viewInsets = FakeViewPadding(bottom: height);
  tester.view.padding = FakeViewPadding(
    bottom: (24.0 - height).clamp(0.0, 24.0),
  );
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump();
}

Future<void> _checkKeyboardDismiss(WidgetTester tester) async {
  final picker = find.byType(EmojiPicker);
  expect(find.byTooltip(':smile:'), findsOneWidget);
  final panelRect = tester.getRect(picker);
  final inputRect = tester.getRect(find.byType(TextField));
  expect(panelRect.height, 320);
  var pickerBuilds = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previous?.call(element, builtOnce);
    if (element.widget is EmojiPicker) pickerBuilds++;
  };
  try {
    for (final height in [240.0, 120.0, 12.0, 0.0]) {
      await _keyboardFrame(tester, height);
      expect(tester.getRect(picker), panelRect);
      expect(tester.getRect(find.byType(TextField)), inputRect);
    }
    expect(pickerBuilds, 0);
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
}

Future<TopicReplySession> _openQuickReply(
  WidgetTester tester, {
  String? recentEmoji,
}) async {
  final source = GlobalKey();
  final session = TopicReplySession(
    topicId: 1,
    localStore: LocalDraftStore(),
    confirmSwitch: (_, _) async => null,
  );
  addTearDown(session.dispose);
  await _pumpHost(
    tester,
    Stack(
      children: [
        Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(key: source, width: 60, height: 40),
        ),
        Positioned.fill(
          child: TopicQuickReplyLayer(
            session: session,
            sourceKey: source,
            hint: '回复',
            onSend: () {},
            onExpand: (_, _, _) {},
          ),
        ),
      ],
    ),
  );
  if (recentEmoji != null) await recordRecentEmoji(recentEmoji);
  session.activeNotifier.value = true;
  session.focusNode.requestFocus();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _keyboardFrame(tester, 320);
  return session;
}

void main() {
  testWidgets('快捷回复切换面板时保持输入连接，收键盘时不重建表情网格', (tester) async {
    final session = await _openQuickReply(tester);
    final field = tester.state(find.byType(EditableText));
    await tester.tap(find.byIcon(Symbols.mood_rounded));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await _checkKeyboardDismiss(tester);

    await tester.tap(find.byIcon(Symbols.keyboard_rounded));
    await tester.pump();
    for (final height in [80.0, 200.0, 320.0]) {
      await _keyboardFrame(tester, height);
      expect(tester.state(find.byType(EditableText)), same(field));
      expect(tester.testTextInput.isVisible, isTrue);
    }
    expect(find.byType(EmojiPicker), findsNothing);
    tester.testTextInput.enterText('继续回复');
    expect(session.text.text, '继续回复');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('最近表情随面板切换连续收展，中途切回也从当前位置展开', (tester) async {
    await _openQuickReply(tester, recentEmoji: 'wave');
    double inputTop() => tester.getTopLeft(find.byType(TextField)).dy;
    final expanded = inputTop();
    final collapsed = expanded + 44;

    await tester.tap(find.byIcon(Symbols.mood_rounded));
    await tester.pump();
    expect(inputTop(), expanded);
    await _keyboardFrame(tester, 240);
    final partial = inputTop();
    expect(partial, allOf(greaterThan(expanded), lessThan(collapsed)));

    await tester.tap(find.byIcon(Symbols.keyboard_rounded));
    await tester.pump();
    expect(inputTop(), closeTo(partial, 0.01));
    await _keyboardFrame(tester, 320);
    expect(inputTop(), allOf(greaterThan(expanded), lessThan(partial)));
    await tester.pumpAndSettle();
    expect(inputTop(), expanded);

    await tester.tap(find.byIcon(Symbols.mood_rounded));
    await tester.pump();
    await _keyboardFrame(tester, 0);
    await tester.pumpAndSettle();
    expect(inputTop(), collapsed);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(inputTop(), collapsed);
    await _keyboardFrame(tester, 120);
    expect(inputTop(), allOf(greaterThan(expanded), lessThan(collapsed)));
    await _keyboardFrame(tester, 320);
    await tester.pumpAndSettle();
    expect(inputTop(), expanded);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Boost 点输入框可切换键盘，收键盘时不重建表情网格', (tester) async {
    await _pumpHost(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBoostInputSheet(context),
            child: const Text('Boost'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Boost'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await _keyboardFrame(tester, 320);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byType(EmojiPicker), findsNothing);
    await tester.tap(find.byIcon(Symbols.emoji_emotions_rounded));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    await _checkKeyboardDismiss(tester);
  });
}
