import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_detail_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_toc_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_toc_panel.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/screen_track.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TopicTocController toc;
  late TopicDetailController detailController;

  setUp(() {
    detailController = TopicDetailController(
      scrollController: AutoScrollController(),
      screenTrack: ScreenTrack(DiscourseService()),
      trackEnabled: false,
    );
    toc = TopicTocController(detailController: detailController);
    // 两级嵌套标题,覆盖深层缩进目录项
    final nodes = ParagraphParser().parse(
      '<h2><a name="p-1-h-a-1" class="anchor" href="#p-1-h-a-1"></a>第一章</h2>'
      '<h3><a name="p-1-h-b-2" class="anchor" href="#p-1-h-b-2"></a>第一节</h3>'
      '<h2><a name="p-1-h-c-3" class="anchor" href="#p-1-h-c-3"></a>第二章</h2>',
    );
    toc.debugSetTocData(TocExtractor.build(nodes, postId: 1, minHeadings: 1)!);
  });

  tearDown(() {
    toc.dispose();
    detailController.dispose();
  });

  Widget panelAt(double width, {bool visible = true, double maxHeight = 400}) {
    return TranslationProvider(
      child: MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: width,
              child: TopicTocSidePanel(
                controller: toc,
                visible: visible,
                maxHeight: maxHeight,
                onToggleVisible: () {},
                onEntryTap: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpFab(
    WidgetTester tester,
    ValueChanged<TocEntry> onEntryTap,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: Scaffold(
              floatingActionButton: TopicTocFab(
                controller: toc,
                onEntryTap: onEntryTap,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
  }

  void loadChapters(int count) {
    final entries = [
      for (var i = 1; i <= count; i++)
        TocEntry(id: 'h-$i', nodeId: 'n-$i', level: 2, text: '第 $i 章'),
    ];
    toc.debugSetTocData(TocData(tree: entries, flat: entries));
  }

  testWidgets('展开动画扫过的全部中间宽度无溢出', (tester) async {
    // 逐档收紧外部宽度，覆盖动画途中标题和深层目录项曾经溢出的情况。
    for (var w = 44.0; w <= 240; w += 7) {
      await tester.pumpWidget(panelAt(w));
      expect(tester.takeException(), isNull, reason: 'width=$w 溢出');
    }
  });

  testWidgets('收起态各宽度无溢出', (tester) async {
    for (var w = 44.0; w <= 240; w += 49) {
      await tester.pumpWidget(panelAt(w, visible: false));
      expect(tester.takeException(), isNull, reason: 'width=$w 溢出');
    }
  });

  testWidgets('短大纲随内容收高，标题贴顶并保留层级缩进', (tester) async {
    await tester.pumpWidget(panelAt(240));
    expect(tester.takeException(), isNull);
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // 计数
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第一节'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    final panel = tester.getRect(find.byType(TopicTocSidePanel));
    expect(panel.height, lessThan(210));
    expect(tester.getTopLeft(find.text('目录')).dy - panel.top, lessThan(24));
    expect(
      panel.bottom - tester.getBottomLeft(find.text('第二章')).dy,
      lessThan(24),
    );
    expect(
      tester.getTopLeft(find.text('第一节')).dx,
      greaterThan(tester.getTopLeft(find.text('第一章')).dx),
    );
  });

  testWidgets('长大纲限制高度，正文滚动后只在目录内定位当前章节', (tester) async {
    loadChapters(60);
    await tester.pumpWidget(panelAt(240, maxHeight: 260));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TopicTocSidePanel)).height, 260);
    final entry = toc.tocData!.flat[45];
    await toc.scrollToHeading(entry, const []);
    await tester.pumpAndSettle();
    expect(find.text(entry.text).hitTestable(), findsOneWidget);
    final rect = tester.getRect(find.byType(TopicTocSidePanel));
    expect(rect.contains(tester.getCenter(find.text(entry.text))), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏短目录按内容收高，整行可点，点选关闭并返回章节', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.reset);
    final selected = <TocEntry>[];
    await pumpFab(tester, selected.add);
    final sheet = find.byType(BottomSheet);
    expect(tester.getSize(sheet).height, lessThan(812 * .5));
    final row = find
        .ancestor(of: find.text('第一节'), matching: find.byType(InkWell))
        .first;
    expect(
      tester.getSize(row).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
    await tester.tapAt(tester.getRect(row).centerRight - const Offset(6, 0));
    await tester.pumpAndSettle();
    expect(selected.single.text, '第一节');
    expect(sheet, findsNothing);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(selected, hasLength(1));
  });

  testWidgets('长目录可上拉扩展，再打开时显示正在阅读的章节', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.reset);
    loadChapters(60);
    await pumpFab(tester, (_) {});
    final sheet = find.byType(BottomSheet);
    final initialHeight = tester.getSize(sheet).height;
    await tester.dragFrom(tester.getCenter(sheet), const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(tester.getSize(sheet).height, greaterThan(initialHeight + 80));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    final entry = toc.tocData!.flat[48];
    await toc.scrollToHeading(entry, const []);
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.text(entry.text).hitTestable(), findsOneWidget);
    final reopened = tester.getRect(sheet);
    await tester.dragFrom(
      reopened.topCenter + const Offset(0, 12),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(sheet).height, greaterThan(reopened.height + 80));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: sheet, matching: find.byType(Scrollable)),
    );
    final offset = scroll.position.pixels;
    await toc.scrollToHeading(toc.tocData!.flat.first, const []);
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, offset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号长标题换行，横屏时仍可在底部安全区上方选章', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = tester.view.padding;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final entry = TocEntry(
      id: 'long',
      nodeId: 'long',
      level: 2,
      text: '穿过长长的沿河老街，找到适合停下来休息的地方',
    );
    toc.debugSetTocData(TocData(tree: [entry], flat: [entry]));
    final selected = <TocEntry>[];
    await pumpFab(tester, selected.add);
    final label = find.text(entry.text);
    expect(tester.getSize(label).height, greaterThan(kMinInteractiveDimension));
    tester.view.physicalSize = const Size(812, 375);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(label).dy, lessThanOrEqualTo(375 - 24));
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(selected, [entry]);
    expect(tester.takeException(), isNull);
  });
}
