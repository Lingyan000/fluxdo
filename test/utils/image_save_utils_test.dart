import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/utils/image_save_utils.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const galChannel = MethodChannel('gal');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tempDir;
  late List<MethodCall> calls;
  String? savedPath;
  Uint8List? savedBytes;
  var hasAccess = true;
  var saveFails = false;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('image_save_test_');
    calls = [];
    savedPath = null;
    savedBytes = null;
    hasAccess = true;
    saveFails = false;
    PlatformUtils.debugDesktopOverride = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tempDir.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(galChannel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'hasAccess':
        case 'requestAccess':
          return hasAccess;
        case 'putImage':
          savedPath = (call.arguments as Map)['path'] as String;
          savedBytes = File(savedPath!).readAsBytesSync();
          if (saveFails) throw PlatformException(code: 'UNEXPECTED');
          return null;
        case 'putImageBytes':
          throw PlatformException(code: 'UNEXPECTED');
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(galChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    PlatformUtils.debugDesktopOverride = null;
    tempDir.deleteSync(recursive: true);
  });

  Future<bool> save(WidgetTester tester, Uint8List bytes, String name) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    final result = await tester.runAsync(
      () => ImageSaveUtils.saveBytes(bytes, fileName: name),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    return result!;
  }

  testWidgets('Android GIF 按原始文件保存，保留两帧并修正默认 PNG 后缀', (tester) async {
    final animation = img.Image(width: 1, height: 1)
      ..setPixelRgb(0, 0, 255, 0, 0);
    animation.addFrame(
      img.Image(width: 1, height: 1)..setPixelRgb(0, 0, 0, 255, 0),
    );
    final bytes = img.encodeGif(animation);

    expect(await save(tester, bytes, 'animation.png'), isTrue);
    expect(p.basename(savedPath!), 'animation.gif');
    expect(savedBytes, orderedEquals(bytes));
    expect(img.decodeGif(savedBytes!)!.numFrames, 2);
    expect(calls.any((call) => call.method == 'putImageBytes'), isFalse);
    expect(File(savedPath!).existsSync(), isFalse);
    expect(tempDir.listSync(), isEmpty);
  });

  for (final brand in ['avif', 'avis']) {
    testWidgets('Android .gif 链接实际为 $brand 时绕过 bytes 格式识别', (tester) async {
      // 这里只验证原始数据的传递和命名，不模拟原生解码。
      final bytes = Uint8List.fromList([
        0,
        0,
        0,
        24,
        ...'ftyp$brand'.codeUnits,
        0,
        0,
        0,
        0,
        ...'avifmif1'.codeUnits,
      ]);
      expect(await save(tester, bytes, 'animation.gif'), isTrue);
      expect(p.basename(savedPath!), 'animation.avif');
      expect(savedBytes, orderedEquals(bytes));
      expect(tempDir.listSync(), isEmpty);
    });
  }

  testWidgets('Android .gif 链接实际为 WebP 时使用真实后缀', (tester) async {
    final bytes = Uint8List.fromList([
      ...'RIFF'.codeUnits,
      16,
      0,
      0,
      0,
      ...'WEBPVP8X'.codeUnits,
      0,
      0,
      0,
      0,
    ]);
    expect(await save(tester, bytes, 'animation.gif'), isTrue);
    expect(p.basename(savedPath!), 'animation.webp');
    expect(savedBytes, orderedEquals(bytes));
  });

  for (final extension in ['png', 'jpg']) {
    testWidgets('Android 普通 $extension 图片仍可原样保存', (tester) async {
      final image = img.Image(width: 1, height: 1);
      final bytes = extension == 'png'
          ? img.encodePng(image)
          : img.encodeJpg(image);
      expect(await save(tester, bytes, 'photo.$extension'), isTrue);
      expect(p.basename(savedPath!), 'photo.$extension');
      expect(savedBytes, orderedEquals(bytes));
    });
  }

  testWidgets('Android 相册写入失败后清理临时文件并返回失败', (tester) async {
    saveFails = true;
    final bytes = img.encodePng(img.Image(width: 1, height: 1));
    expect(await save(tester, bytes, 'photo.png'), isFalse);
    expect(savedPath, isNotNull);
    expect(tempDir.listSync(), isEmpty);
  });

  testWidgets('Android 拒绝权限时不写临时文件或调用相册写入', (tester) async {
    hasAccess = false;
    final bytes = img.encodePng(img.Image(width: 1, height: 1));
    expect(await save(tester, bytes, 'photo.png'), isFalse);
    expect(calls.map((call) => call.method), ['hasAccess', 'requestAccess']);
    expect(tempDir.listSync(), isEmpty);
  });
}
