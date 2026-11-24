import 'package:common_ui/common_ui.dart' show InteractionPageRoute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_reader_page/reader_preferences.dart';
import 'package:fluxdo/pages/topic_reader_page/topic_reader_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/common/paper_texture.dart';
import 'package:fluxdo/widgets/post/small_action_item.dart' show PostTypes;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _makePost({
  required int id,
  required int postNumber,
  required String cooked,
  DateTime? createdAt,
}) {
  final ts = createdAt ?? DateTime.utc(2026, 5, 1, 9, 0);
  return Post(
    id: id,
    username: 'op_user',
    name: '楼主作者',
    avatarTemplate: '/avatar/{size}.png',
    cooked: cooked,
    postNumber: postNumber,
    postType: PostTypes.regular,
    createdAt: ts,
    updatedAt: ts,
    likeCount: 0,
    replyCount: 0,
  );
}

TopicDetail _makeDetail(List<Post> posts, {int? postsCount}) {
  return TopicDetail(
    id: 888,
    title: '深入理解 Flutter 渲染架构',
    slug: 'flutter-render',
    postsCount: postsCount ?? posts.length,
    postStream: PostStream(
      posts: posts,
      stream: posts.map((p) => p.id).toList(),
    ),
    categoryId: 1,
    closed: false,
    archived: false,
    createdAt: DateTime.utc(2026, 5, 1, 9, 0),
    createdBy: TopicUser(
      id: 1,
      username: 'op_user',
      name: '楼主作者',
      avatarTemplate: '/avatar/{size}.png',
    ),
  );
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
  });

  Widget buildApp({
    required TopicDetail detail,
    Future<Post?> Function(int topicId)? firstPostLoader,
    Size size = const Size(420, 840),
    ThemeMode themeMode = ThemeMode.light,
  }) {
    return ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          themeMode: themeMode,
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: MediaQuery(
            data: MediaQueryData(size: size),
            child: TopicReaderPage(
              initialDetail: detail,
              firstPostLoader: firstPostLoader,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('窄屏：首贴沉浸阅读，轻触呼出自适应返回栏与玻璃胶囊，支持目录与排版调节', (tester) async {
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final detail = _makeDetail([
      _makePost(
        id: 1,
        postNumber: 1,
        cooked:
            '<h2>第一章 布局原理</h2><p>这里是第一章的详细技术解析内容。</p>'
            '<h2>第二章 绘制管线</h2><p>这里是第二章的绘制管线说明。</p>',
      ),
    ], postsCount: 15);

    await tester.pumpWidget(buildApp(detail: detail));
    await tester.pumpAndSettle();

    expect(find.text('深入理解 Flutter 渲染架构'), findsWidgets);
    expect(find.textContaining('14 条回复'), findsOneWidget);

    // 轻触正文区呼出顶栏（含平台自适应 BackButton）与底部胶囊
    await tester.tapAt(const Offset(210, 420));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byKey(const ValueKey('reader_capsule_toc')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader_capsule_typesetting')),
      findsOneWidget,
    );

    // 打开目录弹窗并点选标题
    await tester.tap(find.byKey(const ValueKey('reader_capsule_toc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二章 绘制管线').last);
    await tester.pumpAndSettle();

    // 重新呼出浮层并打开排版设置
    await tester.tapAt(const Offset(210, 420));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader_capsule_typesetting')));
    await tester.pumpAndSettle();

    // 排版面板使用离散字号、应用字体方案与纸张底色
    await tester.tap(find.byKey(const ValueKey('reader_paper_paper')));
    await tester.tap(find.byKey(const ValueKey('reader_font_system')));
    await tester.tap(find.byKey(const ValueKey('reader_font_size_19')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(TopicReaderPage)),
    );
    final updatedPrefs = container.read(readerPreferencesProvider);
    expect(updatedPrefs.paperTheme, ReaderPaperTheme.paper);
    expect(updatedPrefs.fontChoice, FontChoice.system);
    expect(updatedPrefs.fontSize, 19.0);
    expect(find.byType(PaperBackground), findsWidgets);
  });

  testWidgets('无标题首贴：窄屏胶囊隐藏目录，宽屏不展开空侧栏', (tester) async {
    tester.view.physicalSize = const Size(420, 840);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final plainDetail = _makeDetail([
      _makePost(id: 9, postNumber: 1, cooked: '<p>没有标题标签的纯段落。</p>'),
    ]);
    await tester.pumpWidget(buildApp(detail: plainDetail));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(210, 420));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader_capsule_toc')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader_capsule_typesetting')),
      findsOneWidget,
    );
  });

  testWidgets('宽屏：有标题时左侧常驻目录默认展开且可收起，首贴未缓存时按需拉取 1 楼', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 模拟从深楼层（#50）进入，initialDetail 中尚未包含 1 楼
    final deepDetail = _makeDetail([
      _makePost(id: 50, postNumber: 50, cooked: '<p>第 50 楼回复</p>'),
    ], postsCount: 50);
    final firstPost = _makePost(
      id: 1,
      postNumber: 1,
      cooked: '<h2>章节一</h2><p>正文一</p><h2>章节二</h2><p>正文二</p>',
    );

    await tester.pumpWidget(
      buildApp(
        detail: deepDetail,
        firstPostLoader: (_) async => firstPost,
        size: const Size(1280, 800),
      ),
    );
    await tester.pumpAndSettle();

    final sidebar = find.byKey(const ValueKey('reader_wide_toc_sidebar'));
    expect(sidebar, findsOneWidget);
    expect(tester.getSize(sidebar).width, 280);
    expect(find.text('章节一'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('reader_toc_sidebar_close')));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 0);
  });

  testWidgets('点击返回按钮正常退出阅读页', (tester) async {
    final detail = _makeDetail([
      _makePost(id: 1, postNumber: 1, cooked: '<h2>第一节</h2><p>正文内容</p>'),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        InteractionPageRoute<void>(
                          builder: (_) => TopicReaderPage(initialDetail: detail),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TopicReaderPage), findsOneWidget);

    await tester.tapAt(const Offset(210, 420));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader_top_back')));
    await tester.pumpAndSettle();
    expect(find.byType(TopicReaderPage), findsNothing);
  });
}
