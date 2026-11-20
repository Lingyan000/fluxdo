import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo_render/fluxdo_render.dart' as content;
import 'package:material_ui/material_ui.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

void main() {
  late Runtime runtime;
  late DynamicContent data;
  var validImage = false;
  late SharedPreferences preferences;
  final requests = <Uri>[];
  final events = <({String name, DynamicMap args})>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    validImage = false;
    requests.clear();
    events.clear();
    data = DynamicContent();
    runtime = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(
          loadImage: (uri) async {
            requests.add(uri);
            return validImage
                ? base64Decode(
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                  )
                : Uint8List(0);
          },
        ),
      );
  });
  tearDown(() => runtime.dispose());
  Future<void> show(
    WidgetTester tester,
    String widget, {
    double scale = 1,
  }) async {
    runtime.update(
      metaversePluginLibraryName,
      parseLibraryFile('import fluxdo; widget Test = $widget;'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: TranslationProvider(
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
                onEvent: (name, args) => events.add((name: name, args: args)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('统计响应数据更新，在小屏大字下自动换行', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    data.update('stats', [
      for (var i = 0; i < 4; i++) {'value': '$i', 'label': '统计项目$i'},
    ]);
    await show(tester, 'Statistics(items:data.stats)', scale: 1.8);
    expect(
      tester.getTopLeft(find.text('统计项目3')).dy,
      greaterThan(tester.getTopLeft(find.text('统计项目0')).dy),
    );
    data.update('stats', [
      {'value': '9', 'label': '当前订阅'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('9'), findsOneWidget);
    expect(find.text('统计项目0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统计加载不展示旧数字，完成后恢复数据且不残留动画', (tester) async {
    data.updateAll({'loading':false,'stats':[{'value':'24','label':'订单'}]});
    await show(tester, 'Statistics(loading:data.loading,items:data.stats)');
    data.update('loading', true);
    await tester.pump();
    expect(find.text('24'), findsNothing);
    expect(find.byType(SkeletonBox), findsWidgets);
    data.update('stats', [{'value':'26','label':'订单'}]);
    data.update('loading', false);
    await tester.pumpAndSettle();
    expect(find.text('26'), findsOneWidget);
    expect(find.byType(Skeleton), findsNothing);
  });

  testWidgets('全宽按钮填满底栏，图标操作的加载与禁用阻止点击', (tester) async {
    data.updateAll({'loading':false,'enabled':true,'selected':false});
    await show(tester, 'PageLayout(loading:false,children:[IconButton(icon:"favorite",selected:data.selected,loading:data.loading,enabled:data.enabled,onPressed:event "save" {})],footer:Button(label:"确认",fullWidth:true,onPressed:event "confirm" {}))');
    final button = find.byType(FilledButton);
    expect(tester.getRect(button).left, 16);
    expect(tester.getRect(button).right, 784);
    await tester.tap(find.byType(IconButton));
    expect(events.single.name, 'save');
    data.update('loading', true); await tester.pump();
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    data.updateAll({'loading':false,'enabled':false,'selected':true}); await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byType(IconButton)).isSelected, isTrue);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    expect(events.length, 1);
  });

  testWidgets('数量输入遵守边界和禁用状态，回传受控值', (tester) async {
    data.updateAll({'value': 1, 'enabled': true});
    await show(
      tester,
      'QuantityInput(value:data.value, min:1, max:2, enabled:data.enabled, onChanged:event "quantity" {})',
    );
    final buttons = find.byType(IconButton);
    expect(tester.widget<IconButton>(buttons.first).onPressed, isNull);
    await tester.tap(buttons.last);
    expect(events.single.args['value'], 2);
    data.update('value', 2);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(buttons.last).onPressed, isNull);
    data.update('enabled', false);
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<IconButton>(buttons).every((w) => w.onPressed == null),
      isTrue,
    );
  });

  testWidgets('Markdown 不生成原始 HTML 媒体，图片只走插件出口', (tester) async {
    data.update('text', '''# 标题

<img src="https://raw.example/a.png"><iframe src="https://raw.example/frame"></iframe>

[无效](javascript:alert)

![受控图片](https://images.example/a.png)

![非法图片](file:///secret.png)

[安全链接](https://example.org/help)
''');
    await show(
      tester,
      'PageLayout(loading:false,children:[Markdown(text:data.text,onLink:event "link" {})])',
    );
    final rendered = tester.widget<content.FluxdoRender>(
      find.byType(content.FluxdoRender),
    );
    expect(rendered.cookedHtml, contains('&lt;img'));
    expect(rendered.cookedHtml, isNot(contains('<iframe')));
    expect(rendered.cookedHtml, isNot(contains('href="javascript:')));
    expect(rendered.cookedHtml, isNot(contains('src="file:')));
    expect(requests.map((u) => u.toString()), ['https://images.example/a.png']);
    expect(events, isEmpty);
    final link = find.byWidgetPredicate(
      (w) =>
          w is content.CachedParagraphText &&
          w.result.span.toPlainText().trim() == '安全链接',
    );
    await tester.ensureVisible(link);
    await tester.tapAt(tester.getTopLeft(link) + const Offset(10, 10));
    await tester.pump();
    expect(events.single.args['url'], 'https://example.org/help');
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片预览使用同一受控出口，关闭只关闭预览层', (tester) async {
    validImage = true;
    await show(
      tester,
      'Image(url:"https://images.example/p.png",width:160,height:120,preview:true)',
    );
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == S.current.metaverse_imagePreview,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(requests.every((u) => u.host == 'images.example'), isTrue);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(RemoteWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复制按钮只在点击时写入，不读取剪贴板', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await show(tester, 'CopyButton(text:"fixture-code",label:"复制测试内容")');
    expect(calls.where((c) => c.method.startsWith('Clipboard.')), isEmpty);
    await tester.tap(find.text('复制测试内容'));
    await tester.pumpAndSettle();
    final clipboard = calls
        .where((c) => c.method.startsWith('Clipboard.'))
        .toList();
    expect(clipboard.single.method, 'Clipboard.setData');
    expect(clipboard.single.arguments, {'text': 'fixture-code'});
  });

  testWidgets('固定工具区保持可见，正文和底部操作可独立访问', (tester) async {
    await show(
      tester,
      'PageLayout(loading:false,toolbar:SearchInput(hint:"固定搜索"),footer:Button(label:"确认"),children:[...for row in data.rows: SizedBox(height:80.0,child:Label(text:row))])',
    );
    data.update('rows', [for (var i = 0; i < 40; i++) '第 $i 项']);
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byType(TextField));
    await tester.drag(find.text('第 0 项'), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(TextField)), before);
    expect(find.text('确认').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
