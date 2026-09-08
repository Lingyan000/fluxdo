import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/search_result.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/search/search_preview_dialog.dart';
import 'package:fluxdo/widgets/search/search_post_card.dart';
import 'package:fluxdo/widgets/common/morphing_dialog_anchor.dart';
import 'package:fluxdo/widgets/common/morphing_dialog_shell.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

SearchPost _post() {
  return SearchPost(
    id: 1,
    username: 'tester',
    avatarTemplate: '',
    createdAt: DateTime.now(),
    likeCount: 5,
    blurb: 'search result blurb text for preview',
    postNumber: 3,
    topic: SearchTopic(
      id: 10,
      slug: 'search-topic',
      title: 'Search Topic Title',
      postsCount: 20,
      views: 100,
      categoryId: 1,
      tags: const [],
      closed: false,
      archived: false,
    ),
  );
}

void main() {
  testWidgets('真实搜索卡片交接画面，退场完成后恢复来源', (tester) async {
    await _pumpSourcePreview(tester);
    final card = find.byType(PaintedTopicCard);
    final cardBounds = tester.getRect(card);
    final expectedAnchor = Rect.fromLTRB(
      cardBounds.left,
      cardBounds.top,
      cardBounds.right,
      cardBounds.bottom - 8,
    );
    await tester.longPress(card);
    await tester.pump();
    final shell = tester.widget<MorphingDialogShell>(
      find.byType(MorphingDialogShell),
    );
    expect(shell.source, isNotNull);
    expect(shell.source!.rect, expectedAnchor);
    expect(_sourceOpacity(tester), 0);
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_sourceOpacity(tester), 0);
    await tester.pumpAndSettle();
    expect(_sourceOpacity(tester), 1);
    expect(tester.getRect(card), cardBounds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('路由被直接移除时也会归还源卡片', (tester) async {
    await _pumpSourcePreview(tester);
    await tester.longPress(find.byType(PaintedTopicCard));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(
      tester.element(find.byType(MorphingDialogShell)),
    )!;
    navigatorKey.currentState!.removeRoute(route);
    await tester.pumpAndSettle();
    expect(_sourceOpacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源在预览期间被移除时，关闭留在当前位置淡出', (tester) async {
    final showSource = ValueNotifier(true);
    addTearDown(showSource.dispose);
    await _pumpSourcePreview(tester, showSource: showSource);
    await tester.longPress(find.byType(PaintedTopicCard));
    await tester.pumpAndSettle();
    final shellFinder = find.byKey(const ValueKey('morphing-shell'));
    final openedRect = tester.getRect(shellFinder);
    showSource.value = false;
    await tester.pump();
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(shellFinder), openedRect);
    await tester.pumpAndSettle();
    expect(shellFinder, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索预览:一镜到底壳从锚点变形展开并收回', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const anchor = Rect.fromLTRB(20, 400, 380, 478);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            navigatorKey: navigatorKey,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) => FilledButton(
                    onPressed: () => SearchPreviewDialog.show(
                      context,
                      post: _post(),
                      anchorRect: anchor,
                    ),
                    child: const Text('open-preview'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-preview'));
    await tester.pump();

    // 首帧:飞行壳精确落在锚点 rect
    final shell = find.byKey(const ValueKey('morphing-shell'));
    expect(shell, findsOneWidget);
    final initialRect = tester.getRect(shell);
    expect(initialRect.left, closeTo(anchor.left, 0.01));
    expect(initialRect.top, closeTo(anchor.top, 0.01));

    // 中途:壳离开锚点向屏幕中心飞行
    await tester.pump(const Duration(milliseconds: 150));
    final midRect = tester.getRect(shell);
    const screenCenter = Offset(400, 300);
    final initialDist = (initialRect.center - screenCenter).distance;
    final midDist = (midRect.center - screenCenter).distance;
    expect(midDist, lessThan(initialDist * 0.6));

    // 落座:壳与内容柱 rect 重合,预览内容完整可见
    await tester.pumpAndSettle();
    final contentFinder = find.byKey(const ValueKey('search-preview-root'));
    expect(contentFinder, findsOneWidget);
    expect(find.text('Search Topic Title'), findsOneWidget);
    final settledShell = tester.getRect(shell);
    final contentRect = tester.getRect(contentFinder);
    expect(settledShell.height, closeTo(contentRect.height, 1));

    // 点 barrier 关闭:壳沿同路径飞回锚点,直到路由移除
    await tester.tapAt(const Offset(10, 10));
    Rect lastShellRect = tester.getRect(shell);
    var guard = 0;
    while (tester.widgetList(shell).isNotEmpty && guard++ < 40) {
      lastShellRect = tester.getRect(shell);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(lastShellRect.top, closeTo(anchor.top, 80));
    expect(find.byKey(const ValueKey('search-preview-root')), findsNothing);
  });
}

double _sourceOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byType(MorphingDialogAnchor),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

Future<void> _pumpSourcePreview(
  WidgetTester tester, {
  ValueNotifier<bool>? showSource,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: const SizedBox.shrink(),
      ),
    ),
  );
  // 排版缓存的分钟心跳常驻进程，在 fakeAsync 之外初始化；时间文案需要已挂载的翻译上下文。
  await tester.runAsync(() async {
    TopicCardLayout.obtainSearch(
      identity: 'preview-test-clock',
      post: _post(),
      width: 400,
      theme: ThemeData(),
      category: null,
    );
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        categoryMapProvider.overrideWith(
          (ref) => const AsyncValue.data(<int, Category>{}),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final card = SearchPostCard(
                  post: _post(),
                  onLongPress: (sourceContext) => SearchPreviewDialog.show(
                    context,
                    sourceContext: sourceContext,
                    post: _post(),
                  ),
                );
                if (showSource == null) return card;
                return ValueListenableBuilder<bool>(
                  valueListenable: showSource,
                  builder: (context, visible, child) =>
                      visible ? child! : const SizedBox.shrink(),
                  child: card,
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
