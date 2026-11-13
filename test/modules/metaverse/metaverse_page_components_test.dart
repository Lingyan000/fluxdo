import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
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
  }) async {
    runtime.update(
      metaversePluginLibraryName,
      parseLibraryFile('import fluxdo; widget Test = $source;'),
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: RemoteWidget(
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
}
