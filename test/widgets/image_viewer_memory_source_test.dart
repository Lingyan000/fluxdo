import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/providers/image_ocr_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/share_utils.dart';
import 'package:fluxdo/widgets/layout/immersive_insets_hold.dart';
import 'package:fluxdo/widgets/common/image_live_overlay.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/preview_fonts.dart';

class _UnavailableOcrModels extends Fake implements OcrModelStore {
  @override
  Future<bool> isReady() async => false;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final platformCalls = <MethodCall>[];
  Uint8List? savedBytes;
  Uint8List? sharedBytes;
  String? savedPath;
  var loads = 0;
  const gal = MethodChannel('gal');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const sharing = MethodChannel('dev.fluttercommunity.plus/share');
  final boundary = GlobalKey();

  setUpAll(() async {
    if (Platform.environment['PLUGIN_IMAGE_SNAPSHOTS'] == '1') {
      await loadPreviewCjkFont();
      await (FontLoader(
            'packages/material_symbols_icons/MaterialSymbolsRounded',
          )..addFont(
            rootBundle.load(
              'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
            ),
          ))
          .load();
    }
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('viewer-source-');
    platformCalls.clear();
    savedBytes = null;
    sharedBytes = null;
    savedPath = null;
    loads = 0;
    PlatformUtils.debugDesktopOverride = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(gal, (call) async {
      platformCalls.add(call);
      if (call.method == 'hasPermission') return true;
      if (call.method == 'putImage') {
        savedPath = (call.arguments as Map)['path'] as String;
        savedBytes = File(savedPath!).readAsBytesSync();
      }
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(sharing, (
      call,
    ) async {
      platformCalls.add(call);
      final file = ((call.arguments as Map)['paths'] as List).single as String;
      sharedBytes = File(file).readAsBytesSync();
      return 'test';
    });
  });

  tearDown(() {
    for (final channel in [gal, paths, sharing]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
    PlatformUtils.debugDesktopOverride = null;
    temp.deleteSync(recursive: true);
  });

  Future<void> show(
    WidgetTester tester,
    Future<Uint8List> Function() load, {
    bool dark = false,
    double scale = 1,
    Size size = const Size(360, 800),
    bool animated = false,
    Future<void>? closeWhen,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ocrModelStoreProvider.overrideWithValue(_UnavailableOcrModels()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: 'MiSans',
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: ImmersiveInsetsHoldScope(
                child: RepaintBoundary(key: boundary, child: child!),
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('查看图片'),
                  onPressed: () => ImageViewerPage.openWithLoader(
                    context,
                    closeWhen: closeWhen,
                    evictOnClose: closeWhen != null,
                    loadImage: () {
                      loads++;
                      return load();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看图片'));
    await tester.pump();
    // 解码和 SVG 光栅化使用真实异步任务，随后才推进路由与手势动画。
    for (var i = 0; i < 100; i++) {
      final views = tester.widgetList<GestureImageView>(
        find.byType(GestureImageView),
      );
      if (views.isNotEmpty) {
        var decoded = false;
        unawaited(
          precacheImage(
            views.single.image,
            tester.element(find.byType(ImageViewerPage)),
          ).then((_) => decoded = true),
        );
        for (var tick = 0; tick < 100 && !decoded; tick++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(decoded, isTrue, reason: '等待真实解码完成');
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    if (animated) {
      await tester.pump(const Duration(milliseconds: 400));
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    if (Platform.environment['PLUGIN_IMAGE_SNAPSHOTS'] != '1') return;
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('build/plugin-image-ui')
          ..createSync(recursive: true);
        File('${folder.path}/$name.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets('私密来源撤销关闭所属查看器并清除解码缓存', (tester) async {
    final revoked = Completer<void>();
    final bytes = img.encodeJpg(img.Image(width: 24, height: 32));
    await show(tester, () async => bytes, closeWhen: revoked.future);
    expect(find.byType(ImageViewerPage), findsOneWidget);
    revoked.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.text('查看图片'), findsOneWidget);
    expect((await MemoryImage(bytes).obtainCacheStatus(configuration:ImageConfiguration.empty))?.keepAlive, isNot(true));
  });

  for (final format in ['jpeg', 'gif']) {
    testWidgets('$format 保存和分享保留原始字节与实际类型，且不重新加载', (tester) async {
      final image = img.Image(width: 240, height: 320)
        ..clear(img.ColorRgb8(65, 120, 170));
      final animated = format == 'gif';
      if (animated) {
        image.loopCount = 1;
        image.frameDuration = 200;
        image.addFrame(
          img.Image(width: 240, height: 320)
            ..clear(img.ColorRgb8(170, 120, 65)),
        );
        image.frames.last.frameDuration = 200;
      }
      final bytes = animated ? img.encodeGif(image) : img.encodeJpg(image);
      await show(tester, () async => bytes, animated: animated);
      if (ShareUtils.canShareFiles) {
        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Symbols.share_rounded));
          for (var i = 0; i < 100 && sharedBytes == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump(const Duration(milliseconds: 400));
        expect(sharedBytes, bytes);
        final share = platformCalls.singleWhere((call) => call.method == 'share');
        expect((share.arguments as Map)['mimeTypes'], ['image/$format']);
      } else {
        expect(find.byIcon(Symbols.share_rounded), findsNothing);
      }
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Symbols.save_alt_rounded));
        for (var i = 0; i < 100 && savedBytes == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(savedBytes, bytes);
      if (animated) expect(img.decodeGif(savedBytes!)!.numFrames, 2);
      expect(savedPath, endsWith(animated ? '.gif' : '.jpg'));
      expect(loads, 1);
      await tester.tap(find.byIcon(Symbols.close_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('SVG 作为内存图复用缩放与工具栏，不执行外链和脚本', (tester) async {
    final bytes = Uint8List.fromList(
      utf8.encode('''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 320">
  <rect width="240" height="320" fill="#4178aa"/>
  <circle cx="120" cy="120" r="65" fill="#eddbb0"/>
  <path d="M30 280L100 170L210 280Z" fill="#406348"/>
  <image href="https://not-requested.invalid/external.png" width="1" height="1"/>
  <script>fetch('https://not-requested.invalid/script')</script>
</svg>'''),
    );
    await show(
      tester,
      () async => bytes,
      dark: true,
      scale: 1.6,
      size: const Size(320, 700),
    );
    expect(find.byType(GestureImageView), findsOneWidget);
    final view = tester.widget<GestureImageView>(find.byType(GestureImageView));
    final memory = (view.image as ResizeImage).imageProvider as MemoryImage;
    expect(img.decodePng(memory.bytes), isNotNull);
    expect(loads, 1);
    await snapshot(tester, 'mobile-dark');
    await tester.flingFrom(const Offset(160, 60), const Offset(0, 310), 1200);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(find.text('查看图片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final svg in [false, true]) {
    for (final mode in ImageLiveOverlayMode.values) {
      testWidgets('${svg ? 'SVG' : '位图'} ${mode.name} 复用受控读取器的已加载图片', (tester) async {
        final bytes = svg
            ? Uint8List.fromList(utf8.encode(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 32">'
                '<rect width="24" height="32" fill="#4178aa"/></svg>',
              ))
            : img.encodeJpg(img.Image(width: 24, height: 32));
        await show(
          tester,
          () async => bytes,
          size: svg ? const Size(320, 700) : const Size(360, 800),
          scale: svg ? 1.6 : 1,
        );
        await tester.tap(find.byIcon(mode == ImageLiveOverlayMode.liveText
            ? Symbols.document_scanner_rounded
            : Symbols.translate_rounded));
        await tester.pumpAndSettle();
        final overlay = tester.widget<ImageLiveOverlay>(find.byType(ImageLiveOverlay));
        expect(overlay.mode, mode);
        expect(overlay.sourceKey, 'memory');
        expect(overlay.gestureController, isNotNull);
        final png = await tester.runAsync(() => overlay.loadImage(CancelToken()));
        final decoded = img.decodePng(png!);
        expect(decoded, isNotNull);
        expect(decoded!.width / decoded.height, closeTo(24 / 32, 0.01));
        expect(loads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('受控读取器的图片可直接进入编辑器且不重复加载', (tester) async {
    await show(tester, () async => img.encodeJpg(img.Image(width: 24, height: 32)));
    await tester.tap(find.byIcon(Symbols.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.current.imageUpload_editImage));
    for (var i = 0; i < 100 && find.byType(ProImageEditor).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProImageEditor), findsOneWidget);
    expect(loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('失败态可关闭且小屏大字无溢出', (tester) async {
    await show(
      tester,
      () async => throw StateError('permission_denied'),
      scale: 1.6,
      size: const Size(320, 700),
    );
    expect(find.text(S.current.common_retry), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Symbols.save_alt_rounded),
          )
          .onPressed,
      isNull,
    );
    for (final icon in [
      Symbols.more_vert_rounded,
      Symbols.edit_rounded,
      Symbols.document_scanner_rounded,
      Symbols.translate_rounded,
    ]) {
      expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon)).onPressed,
        isNull,
      );
    }
    await snapshot(tester, 'error-light');
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
