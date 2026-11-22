import 'dart:async';
import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:fluxdo/widgets/layout/immersive_insets_hold.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
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
  Future<Uint8List> Function(Uri)? imageLoader;
  final imageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  late SharedPreferences preferences;
  final requests = <Uri>[];
  final events = <({String name, DynamicMap args})>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    validImage = false;
    imageLoader = null;
    requests.clear();
    events.clear();
    data = DynamicContent();
    runtime = Runtime()
      ..update(
        metaverseWidgetLibraryName,
        createMetaverseWidgetLibrary(
          loadImage: (uri) async {
            requests.add(uri);
            if (imageLoader != null) return imageLoader!(uri);
            return validImage ? imageBytes : Uint8List(0);
          },
        ),
      );
  });
  tearDown(() => runtime.dispose());
  Future<void> show(
    WidgetTester tester,
    String widget, {
    double scale = 1,
    bool modal = false,
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
              child: ImmersiveInsetsHoldScope(child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  Widget remote() => RemoteWidget(
                    runtime: runtime,
                    widget: const FullyQualifiedWidgetName(
                      metaversePluginLibraryName,
                      'Test',
                    ),
                    data: data,
                    onEvent: (name, args) =>
                        events.add((name: name, args: args)),
                  );
                  if (!modal) return remote();
                  return TextButton(
                    onPressed: () => showAppDialog<void>(
                      context: context,
                      builder: (_) => Dialog(
                        child: SizedBox(
                          width: 300,
                          height: 400,
                          child: remote(),
                        ),
                      ),
                    ),
                    child: const Text('详情'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    if (modal) {
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
    }
    if (validImage) {
      await tester.runAsync(
        () => precacheImage(
          ResizeImage(
            MemoryImage(imageBytes),
            width: (tester.view.physicalSize.longestSide * 3)
                .clamp(2048, 8192)
                .round(),
            height: (tester.view.physicalSize.longestSide * 3)
                .clamp(2048, 8192)
                .round(),
            policy: ResizeImagePolicy.fit,
          ),
          tester.element(find.byType(RemoteWidget)),
        ),
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets('头像图标按钮保留提示、点击和禁用语义', (tester) async {
    validImage = true;
    data.updateAll({'enabled':true});
    await show(tester, 'IconButton(tooltip:"我的士多",enabled:data.enabled,child:Avatar(label:"测试用户",url:"https://images.example/avatar.png",size:28),onPressed:event "account" {})');
    await tester.pumpAndSettle();
    final button = find.byType(IconButton);
    expect(tester.getSize(button).width, greaterThanOrEqualTo(40));
    expect(tester.widget<IconButton>(button).tooltip, '我的士多');
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(button);
    expect(events.single.name, 'account');
    data.update('enabled', false);
    await tester.pump();
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('点裂图重试走强制下载通道，普通展示仍可使用缓存', (tester) async {
    var reads = 0, retries = 0;
    runtime.update(metaverseWidgetLibraryName, createMetaverseWidgetLibrary(
      loadImage: (_) async { reads++; throw StateError('unavailable'); },
      reloadImage: (_) async { retries++; return imageBytes; },
    ));
    await show(tester, 'Image(url:"https://images.example.org/cover.png",width:180,height:140)');
    await tester.runAsync(() => precacheImage(ResizeImage(MemoryImage(imageBytes),
      width: 1024, height: 1024, policy: ResizeImagePolicy.fit), tester.element(find.byType(RemoteWidget))));
    await tester.tap(find.byIcon(Symbols.broken_image_rounded));
    await tester.pumpAndSettle();
    expect([reads, retries], [1, 1]);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });

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

  Finder previewButton() => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.label == S.current.metaverse_imagePreview,
  );

  testWidgets('图片复用公共查看器与现有请求，双击缩放后关闭只退出预览', (tester) async {
    validImage = true;
    await show(
      tester,
      'Image(url:"https://images.example/p.png",width:160,height:120,preview:true)',
    );
    await tester.tap(previewButton());
    await tester.pumpAndSettle();
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.imageUrl, isNull);
    expect(viewer.galleryImages, isNull);
    expect(viewer.imageLoader, isNotNull);
    expect(find.byType(Dialog), findsNothing);
    expect(requests.map((u) => u.toString()), ['https://images.example/p.png']);
    expect(find.byIcon(Symbols.save_alt_rounded), findsOneWidget);
    final image = tester.widget<GestureImageView>(
      find.byType(GestureImageView),
    );
    final point = tester.getCenter(find.byType(GestureImageView));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(image.controller.details!.totalScale, greaterThan(1));
    // 双击会收起工具栏，普通返回仍只退出查看器。
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.byType(RemoteWidget), findsOneWidget);
    expect(requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片尚在加载时可以打开和关闭，迟到结果不会重新打开页面', (tester) async {
    final pending = Completer<Uint8List>();
    imageLoader = (_) => pending.future;
    await show(
      tester,
      'Image(url:"https://images.example/slow.png",width:160,height:120,preview:true)',
    );
    await tester.tap(previewButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ImageViewerPage), findsOneWidget);
    final save = find.widgetWithIcon(IconButton, Symbols.save_alt_rounded);
    expect(tester.widget<IconButton>(save).onPressed, isNull);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    pending.complete(imageBytes);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.byType(RemoteWidget), findsOneWidget);
    expect(requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('查看器重试再次经过插件加载器，拒绝时不回退到公共 URL 下载', (tester) async {
    final pending = Completer<Uint8List>();
    var allowed = false;
    imageLoader = (_) {
      if (requests.length == 1) return pending.future;
      if (!allowed) throw StateError('permission_denied');
      return Future.value(imageBytes);
    };
    await show(
      tester,
      'Image(url:"https://images.example/retry.png",width:160,height:120,preview:true)',
    );
    await tester.tap(previewButton());
    await tester.pump();
    pending.completeError(StateError('permission_denied'));
    await tester.pumpAndSettle();
    expect(find.text(S.current.common_retry), findsOneWidget);
    await tester.tap(find.text(S.current.common_retry));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(find.text(S.current.common_retry), findsOneWidget);
    allowed = true;
    await tester.runAsync(
      () => precacheImage(
        ResizeImage(
          MemoryImage(imageBytes),
          width: 2400,
          height: 2400,
          policy: ResizeImagePolicy.fit,
        ),
        tester.element(find.byType(ImageViewerPage)),
      ),
    );
    await tester.tap(find.text(S.current.common_retry));
    await tester.pumpAndSettle();
    expect(requests, hasLength(3));
    expect(find.text(S.current.common_retry), findsNothing);
    expect(find.byType(GestureImageView), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Symbols.save_alt_rounded),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Markdown 图片也复用公共查看器，预览开关关闭时不响应点击', (tester) async {
    validImage = true;
    data.update('text', '![示例](https://images.example/markdown.png)');
    await show(tester, 'Markdown(text:data.text)');
    await tester.tap(previewButton());
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(requests, hasLength(1));
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    await show(
      tester,
      'Image(url:"https://images.example/plain.png",width:160,height:120)',
    );
    expect(previewButton(), findsNothing);
    expect(find.byType(ImageViewerPage), findsNothing);
  });

  testWidgets('详情弹层内打开大图，关闭后仍保留详情和底层页面', (tester) async {
    validImage = true;
    await show(
      tester,
      'Image(url:"https://images.example/modal.png",width:160,height:120,preview:true)',
      modal: true,
    );
    await tester.tap(previewButton());
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(RemoteWidget), findsOneWidget);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('详情'), findsOneWidget);
    expect(requests, hasLength(1));
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
