import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_plugin_page.dart';
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

void main() {
  late Runtime runtime;
  late DynamicContent data;
  late List<({String name, DynamicMap arguments})> events;

  setUp(() {
    runtime = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(loadImage: (_) async => Uint8List(0)),
      );
    data = DynamicContent();
    events = [];
  });
  tearDown(() => runtime.dispose());

  Future<void> show(
    WidgetTester tester,
    String source, {
    double scale = 1,
    SegmentedCardMode mode = SegmentedCardMode.segmented,
  }) async {
    runtime.update(
      metaversePluginLibraryName,
      parseLibraryFile('import fluxdo; widget Test = $source;'),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(extensions: [SegmentedCardStyle(mode: mode)]),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: MetaversePluginPageFrame(title: '测试页面',
            child: RemoteWidget(
              runtime: runtime,
              widget: const FullyQualifiedWidgetName(
                metaversePluginLibraryName,
                'Test',
              ),
              data: data,
              onEvent: (name, arguments) =>
                  events.add((name: name, arguments: arguments)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  const form = '''FormPage(fields: data.fields, resetKey: data.resetKey,
    loading: data.loading, onChanged: event "change" {}, onSubmit: event "submit" {})''';

  const timeline = '''TimelinePage(identity: data.identity,
    itemKeys: [...for item in data.items: item.id],
    items: [...for item in data.items: SizedBox(height: 80.0, child: Label(text: item.id))],
    hasMore: data.more, loadingMore: data.loadingMore, error: data.error,
    endRevision: data.endRevision, onLoadMore: event "more" {}, onRetry: event "retry" {},
    footer: TextInput(value: data.draft, hint: "消息", variant: "filled", minLines: 1,
      maxLines: 4, maxLength: 10, showCounter: false, readOnly: data.busy, onChanged: event "input" {}))''';

  for (final mode in SegmentedCardMode.values) {
    testWidgets('分组列表跳过隐藏的首中尾条目并响应状态变化 ${mode.name}', (tester) async {
      await show(tester, '''ListPage(items: [
        switch data.extra {true: ListItem(title: "首项"), default: SizedBoxShrink()},
        ListItem(title: "第一行"),
        switch data.extra {true: ListItem(title: "中间项"), default: SizedBoxShrink()},
        ListItem(title: "第二行"),
        switch data.extra {true: ListItem(title: "尾项"), default: SizedBoxShrink()},
        switch data.extra {true: ListItem(title: "另一尾项"), default: SizedBoxShrink()}
      ])''', mode: mode);
      await tester.pumpAndSettle();
      SegmentedCardItem row(String label) => tester.widget<SegmentedCardItem>(
        find.ancestor(of: find.text(label), matching: find.byType(SegmentedCardItem)).first,
      );
      expect(row('第一行').index, 0);
      expect(row('第一行').count, 2);
      expect(row('第二行').index, 1);
      final material = find.ancestor(of: find.text('第二行'), matching: find.byType(Material)).first;
      final shape = tester.widget<Material>(material).shape! as RoundedSuperellipseBorder;
      expect(shape.borderRadius.resolve(TextDirection.ltr).bottomLeft.x, greaterThan(0));
      final firstBottom = tester.getBottomLeft(find.widgetWithText(ListTile, '第一行')).dy;
      final secondTop = tester.getTopLeft(find.widgetWithText(ListTile, '第二行')).dy;
      expect(secondTop - firstBottom, mode == SegmentedCardMode.segmented ? 3 : 0);
      for (final item in tester.widgetList<SegmentedCardItem>(find.byType(SegmentedCardItem))) {
        if (item.gap == 0) {
          expect(tester.getSize(find.byWidget(item)).height, 0);
        }
      }
      data.update('extra', true);
      await tester.pumpAndSettle();
      expect(row('首项').index, 0);
      expect(row('另一尾项').index, 5);
      expect(row('另一尾项').count, 6);
      data.update('extra', false);
      await tester.pumpAndSettle();
      expect(row('第二行').index, 1);
      expect(row('第二行').count, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('全部条目隐藏时显示空态，保留订阅并能恢复单行完整圆角', (tester) async {
    await show(tester, '''ListPage(emptyTitle: "没有可见项目", items: [
      switch data.visible {true: ListItem(title: "可见项目"), default: SizedBoxShrink()}
    ])''');
    await tester.pumpAndSettle();
    expect(find.text('没有可见项目'), findsOneWidget);
    data.update('visible', true);
    await tester.pumpAndSettle();
    expect(find.text('没有可见项目'), findsNothing);
    final row = tester.widget<SegmentedCardItem>(find.byType(SegmentedCardItem));
    expect((row.index, row.count), (0, 1));
    data.update('visible', false);
    await tester.pumpAndSettle();
    expect(find.text('没有可见项目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长列表保持懒加载，到达尾部才排除隐藏尾项', (tester) async {
    data.update('rows', [for (var i = 0; i < 120; i++) '项目 $i']);
    await show(tester, '''ListPage(items: [
      ...for row in data.rows: SizedBox(height: 64.0, child: Label(text: row)),
      SizedBoxShrink(), SizedBoxShrink()
    ])''');
    await tester.pumpAndSettle();
    expect(find.text('项目 119'), findsNothing);
    expect(find.byType(SegmentedCardItem).evaluate().length, lessThan(30));
    await tester.scrollUntilVisible(find.text('项目 119'), 700);
    await tester.pumpAndSettle();
    final last = tester.widget<SegmentedCardItem>(find.ancestor(
      of: find.text('项目 119'), matching: find.byType(SegmentedCardItem),
    ).first);
    expect((last.index, last.count), (119, 120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间线首次定位、历史追加和新消息保留阅读位置，主动操作回到最新', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var rows = [for (var i = 40; i > 0; i--) {'id': '记录 $i'}];
    data.updateAll({'identity': 'one', 'items': rows, 'more': true});
    await show(tester, timeline);
    await tester.pumpAndSettle();
    final list = find.byType(CustomScrollView);
    final controller = tester.widget<CustomScrollView>(list).controller!;
    expect(controller.offset, closeTo(-16, 1));
    expect(find.text('记录 40').hitTestable(), findsOneWidget);
    expect(events, isEmpty);
    controller.jumpTo(600);
    await tester.pumpAndSettle();
    final anchor = find.text('记录 30');
    final before = tester.getTopLeft(anchor).dy;
    rows = [...rows, {'id': '记录 0'}];
    data.update('items', rows);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
    rows = [for (var i = 100; i > 40; i--) {'id': '记录 $i'}, ...rows];
    data.update('items', rows);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
    expect(find.text(S.current.metaverse_timelineLatest), findsOneWidget);
    await tester.tap(find.text(S.current.metaverse_timelineLatest));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(-16, 1));
    expect(find.text('记录 100').hitTestable(), findsOneWidget);
    controller.jumpTo(400);
    await tester.pumpAndSettle();
    data.update('endRevision', 1);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(-16, 1));
    expect(find.text('记录 100').hitTestable(), findsOneWidget);
    controller.jumpTo(400);
    await tester.pumpAndSettle();
    data.update('identity', 'two');
    data.update('items', [{'id': '另一会话'}]);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(-16, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间线短内容上滑历史分页只触发一次，错误可重试', (tester) async {
    data.updateAll({'items': [{'id': '一条记录'}], 'more': true});
    await show(tester, timeline);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 240));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 240));
    await tester.pumpAndSettle();
    expect(events.where((e) => e.name == 'more'), hasLength(1));
    data.update('error', '历史加载失败');
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.common_retry));
    expect(events.last.name, 'retry');
    data.update('error', '');
    data.update('loadingMore', true);
    await tester.pump();
    data.update('loadingMore', false);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 240));
    await tester.pumpAndSettle();
    expect(events.where((e) => e.name == 'more'), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入随内容增高、按可见字符限制、发送只读与键盘安全区', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    data.update('items', [{'id': '最新记录'}]);
    await show(tester, timeline, scale: 1.5);
    final input = find.byType(TextField);
    final initial = tester.getSize(input).height;
    await tester.enterText(input, '一\n二\n三');
    await tester.pumpAndSettle();
    expect(tester.getSize(input).height, greaterThan(initial));
    await tester.enterText(input, '😀' * 12);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, '😀' * 10);
    data.update('busy', true);
    await tester.pump();
    expect(tester.widget<TextField>(input).readOnly, isTrue);
    expect(tester.getRect(input).bottom, lessThanOrEqualTo(666));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.getRect(input).bottom, lessThanOrEqualTo(420));
    expect(find.text('最新记录').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('时间线条件隐藏底栏时仍为手势区留白，显示底栏不重复留白', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await show(tester, '''TimelinePage(identity: "one", itemKeys: ["1"],
      items: [SizedBox(height: 60.0, child: Label(text: "记录"))],
      footer: switch data.footer {true: Button(label: "发送"), default: SizedBoxShrink()})''');
    await tester.pumpAndSettle();
    final scroll = tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!;
    expect(scroll.position.minScrollExtent, -50);
    expect(scroll.offset, -50);
    expect(tester.getRect(find.text('记录')).bottom, lessThanOrEqualTo(794));
    data.update('footer', true);
    await tester.pumpAndSettle();
    expect(scroll.position.minScrollExtent, -16);
    expect(scroll.offset, -16);
    expect(tester.getRect(find.widgetWithText(FilledButton, '发送')).bottom, lessThanOrEqualTo(810));
    data.update('footer', false);
    await tester.pumpAndSettle();
    expect(scroll.offset, -50);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表单校验必填、回传原生字段并在加载时禁用', (tester) async {
    data.update('fields', [
      {'name': 'title', 'label': '标题', 'required': true},
      {'name': 'enabled', 'label': '启用', 'type': 'toggle', 'value': false},
      {
        'name': 'kind',
        'label': '类型',
        'type': 'choice',
        'required': true,
        'options': [
          {'value': 'one', 'label': '第一项'},
          {'value': 'two', 'label': '第二项'},
        ],
      },
    ]);
    await show(tester, form);
    await tester.tap(
      find.widgetWithText(FilledButton, S.current.metaverse_formSubmit),
    );
    await tester.pumpAndSettle();
    expect(find.text(S.current.metaverse_formRequired('标题')), findsOneWidget);
    expect(events.where((event) => event.name == 'submit'), isEmpty);
    await tester.enterText(find.byType(TextFormField), '新的内容');
    await tester.tap(find.text('启用'));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二项').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, S.current.metaverse_formSubmit),
    );
    await tester.pumpAndSettle();
    expect(events.last.arguments['values'], {
      'title': '新的内容',
      'enabled': true,
      'kind': 'two',
    });
    data.update('loading', true);
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('普通重绘保留输入，脚本显式值变更和 resetKey 可以重置', (tester) async {
    data.update('fields', [
      {'name': 'title', 'label': '标题', 'value': '初始'},
    ]);
    await show(tester, form);
    await tester.enterText(find.byType(TextFormField), '用户输入');
    data.update('loading', true);
    await tester.pump();
    data.update('loading', false);
    await tester.pump();
    expect(find.text('用户输入'), findsOneWidget);
    data.update('resetKey', 'reset-1');
    await tester.pumpAndSettle();
    expect(find.text('初始'), findsOneWidget);
    data.update('fields', [
      {'name': 'title', 'label': '标题', 'value': '服务值'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('服务值'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重复字段显示定义错误，外部超长值和服务错误阻止提交', (tester) async {
    data.update('fields', [
      {'name': 'title'},
      {'name': 'title'},
    ]);
    await show(tester, form);
    expect(find.text(S.current.metaverse_formInvalidFields), findsOneWidget);
    data.update('fields', [
      {'name': 'title', 'label': '标题', 'value': '超长文本', 'maxLength': 2},
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text(S.current.metaverse_formTooLong('标题', 2)), findsOneWidget);
    expect(events.where((event) => event.name == 'submit'), isEmpty);
    data.update('fields', [
      {'name': 'title', 'label': '标题', 'value': '正常', 'error': '服务校验失败'},
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('服务校验失败'), findsOneWidget);
    expect(events.where((event) => event.name == 'submit'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表空态、重试、分页与刷新保留内容', (tester) async {
    data.update('items', <Object>[]);
    await show(
      tester,
      '''ListPage(loading: data.loading, error: data.error,
      hasMore: data.hasMore, onRetry: event "retry" {}, onLoadMore: event "more" {},
      items: [...for item in data.items: ListItem(title: item.title, onTap: event "open" {id: item.id})])''',
    );
    expect(find.text(S.current.common_noData), findsOneWidget);
    data.update('error', '连接失败');
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(OutlinedButton, S.current.common_retry),
    );
    expect(events.last.name, 'retry');
    data.update('error', '');
    data.update('items', [
      {'id': 'one', 'title': '条目一'},
    ]);
    data.update('hasMore', true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('条目一'));
    expect(events.last.arguments, {'id': 'one'});
    await tester.tap(
      find.widgetWithText(OutlinedButton, S.current.common_more),
    );
    expect(events.last.name, 'more');
    data.update('loading', true);
    await tester.pump();
    expect(find.text('条目一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情底部操作在窄屏大字体下可点击', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(
      tester,
      '''DetailPage(header: Label(text: "详情", style: "headlineSmall"),
      sections: [Surface(child: Label(text: "说明内容")), Surface(child: Label(text: "更多内容"))],
      actions: ActionBar(actions: [Button(label: "取消", variant: "text", onPressed: event "cancel" {}),
        Button(label: "确认并继续", onPressed: event "confirm" {})]))''',
      scale: 2,
    );
    await tester.pumpAndSettle();
    expect(find.text('确认并继续').hitTestable(), findsOneWidget);
    await tester.tap(find.text('确认并继续'));
    expect(events.last.name, 'confirm');
    expect(tester.takeException(), isNull);
  });

  testWidgets('长表单键盘弹出后仍能滚动编辑，提交位于键盘上方', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    data.update('fields', [
      for (var index = 0; index < 8; index++)
        {'name': 'field$index', 'label': '字段 $index'},
    ]);
    await show(tester, form, scale: 1.4);
    await tester.ensureVisible(find.byType(TextFormField).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '最后一项');
    final submit = find.widgetWithText(
      FilledButton,
      S.current.metaverse_formSubmit,
    );
    expect(submit.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(submit).dy, lessThanOrEqualTo(420));
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect((events.last.arguments['values'] as Map)['field7'], '最后一项');
    expect(tester.takeException(), isNull);
  });

  testWidgets('字段删除与选项变化同步提交内容', (tester) async {
    data.update('fields', [
      {'name': 'removed', 'value': '旧值'},
      {
        'name': 'kind',
        'type': 'choice',
        'value': 'one',
        'options': [
          {'value': 'one'},
          {'value': 'two'},
        ],
      },
    ]);
    await show(tester, form);
    data.update('fields', [
      {
        'name': 'kind',
        'type': 'choice',
        'value': 'one',
        'options': [
          {'value': 'two'},
        ],
      },
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    expect(events.last.arguments['values'], {'kind': null});
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情支持空态和错误重试', (tester) async {
    await show(
      tester,
      'DetailPage(error: data.error, onRetry: event "retry" {})',
    );
    expect(find.text(S.current.common_noData), findsOneWidget);
    data.update('error', '服务暂不可用');
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(OutlinedButton, S.current.common_retry),
    );
    expect(events.last.name, 'retry');
    expect(tester.takeException(), isNull);
  });

  testWidgets('空底栏不占位，滚动延伸到手势区，末项和固定按钮留安全间距', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390,844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    await show(tester, 'PageLayout(loading:false,footer:switch data.footer {true: Button(label:"确认"),default:SizedBoxShrink()},children:[...for row in data.rows:SizedBox(height:100.0,child:Label(text:row))])');
    data.update('rows', [for(var i=0;i<20;i++) '行 $i']);
    await tester.pumpAndSettle();
    final screenHeight=tester.view.physicalSize.height/tester.view.devicePixelRatio;
    expect(tester.getRect(find.byType(SingleChildScrollView).last).bottom, screenHeight);
    final scroll=Scrollable.of(tester.element(find.text('行 19'))).position;
    scroll.jumpTo(scroll.maxScrollExtent);await tester.pumpAndSettle();
    expect(tester.getRect(find.text('行 19')).bottom, lessThan(screenHeight-34));
    data.update('footer',true);await tester.pumpAndSettle();
    expect(tester.getRect(find.widgetWithText(FilledButton,'确认')).bottom, lessThanOrEqualTo(screenHeight-34));
    expect(tester.takeException(),isNull);
  });

  for(final page in ['ListPage','GridPage']) {
    testWidgets('$page 首屏骨架可替换，刷新有内容时不插入占位或移动首项', (tester) async {
      data.update('loading',true);data.update('items',<Object>[]);
      await show(tester, '$page(loading:data.loading,header:SizedBoxShrink(),actions:SizedBoxShrink(),loadingPlaceholder:Skeleton(child:SkeletonBox(height:80)),items:[...for item in data.items:ListItem(title:item)])');
      expect(find.byType(SkeletonBox),findsOneWidget);
      data.update('items',['已有内容']);data.update('loading',false);
      await tester.pumpAndSettle();
      final before=tester.getRect(find.text('已有内容'));
      data.update('loading',true);await tester.pump();
      expect(find.byType(SkeletonBox),findsNothing);
      expect(tester.getRect(find.text('已有内容')),before);
      expect(tester.takeException(),isNull);
    });
  }
}
