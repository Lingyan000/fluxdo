import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/utils/fluxdo_render_callbacks.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/common/image_lift_menu.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo/services/image_decode_spec_memo.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo/widgets/content/discourse_image.dart';

void main() {
  testWidgets('普通图片的 Hero 和查看器记录使用屏上图片的实际 provider', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    const url = 'https://test.invalid/cached-picture.jpg';
    final expected = ResizeImage(
      discourseImageProvider(url),
      width: 80,
      height: 60,
      policy: ResizeImagePolicy.fit,
    );
    final key = await expected.obtainKey(ImageConfiguration.empty);
    final pixels = (await tester.runAsync(
      () => createTestImage(width: 80, height: 60, cache: false),
    ))!;
    tester.binding.imageCache.putIfAbsent(
      key,
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: pixels))),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: DiscourseImage(
            url: url,
            width: 80,
            height: 60,
            heroTag: 'cached-picture',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final source = tester.widget<Image>(find.byType(Image)).image;
    expect(
      tester.widget<HeroImage>(find.byType(HeroImage)).flightImage,
      same(source),
    );
    expect(ImageDecodeSpecMemo.peek(url), same(source));
    expect(await source.obtainKey(ImageConfiguration.empty), key);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.imageCache.evict(key);
  });

  testWidgets('帖子里按住图片，预览第一帧直接使用源图的解码流', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    const url = 'https://test.invalid/lift-picture.png';
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
    final render = FluxdoRenderCallbacks.generic(heroTagNamespace: 'lift');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Center(
            child: Builder(
              builder: (context) => render.imageContentBuilder(
                context,
                const ImageRun(src: url, width: 80, height: 60),
                1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final source = tester.widget<Image>(find.byType(Image)).image;
    final held = await tester.startGesture(
      tester.getCenter(find.byType(ImageLiftSource)),
    );
    await tester.pump(const Duration(milliseconds: 360));
    final preview = find.descendant(
      of: find.byType(ClipRSuperellipse),
      matching: find.byType(Image),
    );
    expect(tester.widget<Image>(preview).image, same(source));
    final raw = find.descendant(of: preview, matching: find.byType(RawImage));
    expect(tester.widget<RawImage>(raw).image, isNotNull);
    expect(find.text(S.current.image_viewFull), findsOneWidget);
    await held.up();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(ImageLiftMenu.activeSource.value, isNull);
    // 同一个帖子入口接收真实鼠标右键。宽窗操作面板贴近点击点，窄窗使用指针菜单。
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    for (final (width, desktop) in [
      (1200.0, true),
      (500.0, true),
      (500.0, false),
    ]) {
      PlatformUtils.debugDesktopOverride = desktop;
      tester.view.physicalSize = Size(width, 780);
      await tester.pumpAndSettle();
      final at =
          tester.getCenter(find.byType(ImageLiftSource)) + const Offset(15, 4);
      final mouse = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      if (width == 1200) {
        expect(ImageLiftMenu.activeSource.value, isNotNull);
        final row = tester.getRect(
          find.ancestor(
            of: find.text(S.current.image_viewFull),
            matching: find.byType(ListTile),
          ),
        );
        expect(row.contains(at), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        expect(ImageLiftMenu.activeSource.value, isNull);
        expect(find.text(S.current.image_viewFull), findsOneWidget);
        await navigatorKey.currentState!.maybePop();
      }
      await tester.pumpAndSettle();
      expect(find.text(S.current.image_viewFull), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.imageCache.evict(key);
  });
}
