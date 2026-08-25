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

Topic _topic({String title = 'Preview Topic'}) {
  return Topic(
    id: 1,
    title: title,
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
  testWidgets('短内容预览卡片按内容自适应高度', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

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
                firstPostLoader: () async => '<p>Loaded content</p>',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    final previewSize = tester.getSize(
      find.byKey(const ValueKey('topic-preview-root')),
    );

    expect(previewSize.height, lessThan(600 * 0.7));
  });

  testWidgets('长内容预览卡片高度不超过屏幕上限', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final longTitle = List.filled(80, 'Long preview title').join(' ');

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
                topic: _topic(title: longTitle),
                firstPostLoader: () async => '<p>Loaded content</p>',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final previewSize = tester.getSize(
      find.byKey(const ValueKey('topic-preview-root')),
    );
    expect(previewSize.height, lessThanOrEqualTo(600 * 0.7));
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

  testWidgets('一镜到底:壳从锚点变形展开,关闭沿同路径收回', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // 长按卡片的屏幕 rect(已裁底部间距),屏幕 800x600
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
            home: const Scaffold(body: _OpenPreviewHarness(anchorRect: anchor)),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-preview'));
    await tester.pump();

    // 首帧:飞行壳精确落在锚点 rect(内容柱尚未布局,动画钳在 0)
    final shell = find.byKey(const ValueKey('morphing-shell'));
    expect(shell, findsOneWidget);
    final initialRect = tester.getRect(shell);
    expect(initialRect.left, closeTo(anchor.left, 0.01));
    expect(initialRect.top, closeTo(anchor.top, 0.01));
    expect(initialRect.width, closeTo(anchor.width, 0.01));
    expect(initialRect.height, closeTo(anchor.height, 0.01));

    // 中途:壳离开锚点向屏幕中心飞行(中心距离显著收窄)
    await tester.pump(const Duration(milliseconds: 150));
    final midRect = tester.getRect(shell);
    const screenCenter = Offset(400, 300);
    final initialDist = (initialRect.center - screenCenter).distance;
    final midDist = (midRect.center - screenCenter).distance;
    expect(midDist, lessThan(initialDist * 0.6));

    // 落座:壳与内容柱 rect 重合(内容自始至终嵌在壳内),预览完整可见
    await tester.pumpAndSettle();
    expect(shell, findsOneWidget);
    final contentFinder = find.byKey(const ValueKey('topic-preview-root'));
    expect(contentFinder, findsOneWidget);
    expect(find.text('Preview Topic'), findsOneWidget);
    final settledShell = tester.getRect(shell);
    final contentRect = tester.getRect(contentFinder);
    expect(settledShell.left, closeTo(contentRect.left, 1));
    expect(settledShell.top, closeTo(contentRect.top, 1));
    expect(settledShell.width, closeTo(contentRect.width, 1));
    expect(settledShell.height, closeTo(contentRect.height, 1));

    // 点 barrier 关闭:壳沿同路径飞回锚点。tapAt 内部泵一帧处理事件
    // 并启动 reverse;逐帧小步推进,记录壳最后的 rect —— 应收敛回
    // 锚点附近(同路径收回的收尾),直到路由移除、壳消失。
    await tester.tapAt(const Offset(10, 10));
    Rect lastShellRect = tester.getRect(shell);
    var guard = 0;
    while (tester.widgetList(shell).isNotEmpty && guard++ < 40) {
      lastShellRect = tester.getRect(shell);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(lastShellRect.top, closeTo(anchor.top, 80));
    expect(lastShellRect.left, closeTo(anchor.left, 80));

    // 收回完成:预览彻底退出
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('topic-preview-root')), findsNothing);
  });

  testWidgets('一镜到底:正文加载中落座,壳与内容同高(无底部空白)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // loader 挂起:正文区停留 loading spinner,内容较矮 —— 回归
    // OverflowBox minHeight 继承父 tight 约束导致的壳高失真自锁
    final loader = Completer<String?>();
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
                    onPressed: () => TopicPreviewDialog.show(
                      context,
                      topic: _topic(),
                      firstPostLoader: () => loader.future,
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
    // loading spinner 常转,不能 pumpAndSettle;定长泵过 350ms 动画
    // 后再泵两帧,等 postFrame 尺寸同步的重建落地
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final shellRect = tester.getRect(
      find.byKey(const ValueKey('morphing-shell')),
    );
    final contentRect = tester.getRect(
      find.byKey(const ValueKey('topic-preview-root')),
    );
    expect(shellRect.left, closeTo(contentRect.left, 1));
    expect(shellRect.top, closeTo(contentRect.top, 1));
    expect(shellRect.width, closeTo(contentRect.width, 1));
    expect(shellRect.height, closeTo(contentRect.height, 1));
  });
}

class _OpenPreviewHarness extends StatelessWidget {
  const _OpenPreviewHarness({required this.anchorRect});

  final Rect anchorRect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton(
        onPressed: () => TopicPreviewDialog.show(
          context,
          topic: _topic(),
          firstPostLoader: () async => '<p>Loaded content</p>',
          anchorRect: anchorRect,
        ),
        child: const Text('open-preview'),
      ),
    );
  }
}
