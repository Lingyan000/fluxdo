import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('正文图片、带链接图片和空白处切换平台光标', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const nativeChannel = MethodChannel('com.fluxdo/image_cursor');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add('native/${call.method}');
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.mouseCursor, (
      call,
    ) async {
      expect(call.method, 'activateSystemCursor');
      calls.add('system/${call.arguments['kind']}');
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeChannel, null);
      messenger.setMockMethodCallHandler(SystemChannels.mouseCursor, null);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    const url = 'https://test.invalid/post-cursor.png';
    final provider = ResizeImage(
      discourseImageProvider(url),
      width: 80,
      height: 4096,
      policy: ResizeImagePolicy.fit,
    );
    final key = await provider.obtainKey(ImageConfiguration.empty);
    final pixels = (await tester.runAsync(
      () => createTestImage(width: 80, height: 60, cache: false),
    ))!;
    tester.binding.imageCache.putIfAbsent(
      key,
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: pixels))),
    );
    addTearDown(() => tester.binding.imageCache.evict(key));
    const img = '<img src="$url" width="80" height="60">';
    final opened = <String>[];
    final render = FluxdoRenderCallbacks.generic(heroTagNamespace: 'cursor');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: FluxdoRender(
              cookedHtml:
                  '<div class="lightbox-wrapper"><a class="lightbox" href="$url">'
                  '$img</a></div><p><a href="/linked">$img</a></p>',
              imageContentBuilder: render.imageContentBuilder,
              linkHandler: (_, href) => opened.add(href),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final images = find.byType(HeroImage);
    expect(images, findsNWidgets(2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(images.first));
    final zoom = defaultTargetPlatform == TargetPlatform.linux
        ? 'system/zoomIn'
        : 'native/zoomIn';
    expect(calls.last, zoom);
    final link = tester.getCenter(images.last);
    await mouse.moveTo(link);
    expect(calls.last, 'system/click');
    await mouse.down(link);
    await mouse.up();
    expect(opened, ['/linked']);
    await mouse.moveTo(tester.getCenter(images.first));
    expect(calls.last, zoom);
    await mouse.moveTo(
      tester.getBottomRight(find.byType(Scaffold)) - const Offset(1, 1),
    );
    expect(calls.last, 'system/basic');
    await mouse.moveTo(tester.getCenter(images.first));
    expect(calls.last, zoom);
    await tester.pumpWidget(const SizedBox());
    expect(calls.last, 'system/basic');
    await mouse.removePointer();
  }, variant: TargetPlatformVariant.desktop());
}
