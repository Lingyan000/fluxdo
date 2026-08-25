import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_detail_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/controllers/topic_toc_controller.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_toc_panel.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/screen_track.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

/// 回归:宽屏 TOC 面板收起→展开的宽度动画(44↔240)途中,展开内容在
/// 中间宽度下布局曾 RenderFlex 溢出(header Row 溢出 ~49px、depth-1
/// 目录项在 44px 宽恰溢 3.0px)。修复:内容恒按完整宽度布局 + 外层裁剪。
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

  Widget panelAt(double width, {bool visible = true}) {
    return TranslationProvider(
      child: MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 400,
              child: TopicTocSidePanel(
                controller: toc,
                visible: visible,
                maxHeight: 400,
                onToggleVisible: () {},
                onEntryTap: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('展开动画扫过的全部中间宽度无溢出', (tester) async {
    // AnimatedContainer 200ms 扫过 44→240;逐档静态铺同款宽度即等价覆盖
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

  testWidgets('正常展开渲染:标题/计数/目录项齐全', (tester) async {
    await tester.pumpWidget(panelAt(240));
    expect(tester.takeException(), isNull);
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // 计数
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第一节'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
  });
}
