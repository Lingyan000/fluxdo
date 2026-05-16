import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/topic/topic_preview_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic _topic() {
  return Topic(
    id: 1,
    title: 'Preview Topic',
    slug: 'preview-topic',
    postsCount: 10,
    replyCount: 9,
    views: 120,
    likeCount: 5,
    categoryId: '1',
    excerpt: 'fallback excerpt',
  );
}

void main() {
  testWidgets('加载前后预览卡片高度保持不变', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final loader = Completer<String?>();

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
              body: TopicPreviewDialog(
                topic: _topic(),
                firstPostLoader: () => loader.future,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    final before = tester.getSize(
      find.byKey(const ValueKey('topic-preview-root')),
    );

    loader.complete('<p>Loaded content</p>');
    await tester.pumpAndSettle();

    final after = tester.getSize(
      find.byKey(const ValueKey('topic-preview-root')),
    );
    expect(after.height, before.height);
  });

  testWidgets('正文未加载完时底部自定义面板也能立即显示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final loader = Completer<String?>();

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
              body: TopicPreviewDialog(
                topic: _topic(),
                firstPostLoader: () => loader.future,
                customActionPanelBuilder: (_) =>
                    const Text('quick-editor-ready'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.text('quick-editor-ready'), findsOneWidget);
  });

  testWidgets('自定义编辑面板会放到预览卡顶部而不是卡片外侧', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final loader = Completer<String?>();

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
              body: TopicPreviewDialog(
                topic: _topic(),
                firstPostLoader: () => loader.future,
                customActionPanelBuilder: (_) => Container(
                  key: const ValueKey('preview-edit-panel'),
                  child: const Text('quick-editor-ready'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final panelTop = tester
        .getTopLeft(find.byKey(const ValueKey('preview-edit-panel')))
        .dy;
    final titleTop = tester.getTopLeft(find.text('Preview Topic')).dy;

    expect(panelTop, lessThan(titleTop));
  });
}
