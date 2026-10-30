import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:fluxdo/services/sticker_thumbnail_provider.dart';

Future<ui.Image> makeImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(2, 2);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('图像缓存key区分代数和优先级', () async {
    const normal = StickerThumbnailProvider('a.avif', targetSize: 20);
    const high = StickerThumbnailProvider(
      'a.avif',
      targetSize: 20,
      priority: DownloadPriority.high,
    );
    final old = await normal.obtainKey(ImageConfiguration.empty);
    expect(old, isNot(await high.obtainKey(ImageConfiguration.empty)));
    StickerThumbnailProvider.cancelInflight();
    expect(old, isNot(await normal.obtainKey(ImageConfiguration.empty)));
  });

  test('解码失败后可重试，不保留失败任务', () async {
    final loader = StickerThumbnailFirstFrameLoader();
    await expectLater(
      loader.load(
        'a',
        decode: () async => throw StateError('解码失败'),
        cache: (_) async {},
      ),
      throwsStateError,
    );
    final original = await makeImage();
    final image = await loader.load(
      'a',
      decode: () async => original,
      cache: (_) async {},
    );
    image.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(original.debugDisposed, isTrue);
  });

  test('同代可见请求接管预热，不受组切换取消', () async {
    final loader = StickerThumbnailFirstFrameLoader();
    final decode = Completer<ui.Image>();
    var keepWarming = true;
    final warm = loader.load('a', visible: false,
        shouldContinue: () => keepWarming,
        decode: () => decode.future, cache: (_) async {});
    final visible = loader.load('a',
        decode: () async => throw StateError('不应再次解码'),
        cache: (_) async {});
    keepWarming = false;
    final original = await makeImage();
    decode.complete(original);
    (await warm).dispose();
    (await visible).dispose();
    await Future<void>.delayed(Duration.zero);
    expect(original.debugDisposed, isTrue);
  });

  test('首帧不等待缓存，预热和可见请求共享解码且独立释放', () async {
    final loader = StickerThumbnailFirstFrameLoader();
    final decoded = Completer<ui.Image>();
    final write = Completer<void>();
    ui.Image? cacheHandle;
    var decodes = 0;
    Future<ui.Image> load() => loader.load(
      'a',
      decode: () {
        decodes++;
        return decoded.future;
      },
      cache: (image) {
        cacheHandle = image;
        return write.future;
      },
    );
    final warm = load();
    final visible = load();
    final original = await makeImage();
    decoded.complete(original);
    final first = await warm;
    final second = await visible;
    expect(decodes, 1);
    expect(write.isCompleted, isFalse);
    expect(first.isCloneOf(second), isTrue);
    first.dispose();
    expect(second.debugDisposed, isFalse);
    final third = await load();
    expect(decodes, 1);
    third.dispose();
    second.dispose();
    expect(cacheHandle!.debugDisposed, isFalse);
    write.complete();
    await Future<void>.delayed(Duration.zero);
    expect(cacheHandle!.debugDisposed, isTrue);
    expect(original.debugDisposed, isTrue);
  });

  test('缓存失败不重解且所有内部句柄释放', () async {
    final loader = StickerThumbnailFirstFrameLoader();
    final original = await makeImage();
    var decodes = 0;
    final image = await loader.load(
      'a',
      decode: () async {
        decodes++;
        return original;
      },
      cache: (_) async => throw StateError('写盘失败'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(decodes, 1);
    expect(original.debugDisposed, isTrue);
    expect(image.debugDisposed, isFalse);
    image.dispose();
  });

  test('取消后的解码图释放，新一代不等待旧任务', () async {
    final loader = StickerThumbnailFirstFrameLoader();
    final oldDecode = Completer<ui.Image>();
    var writes = 0;
    final old = loader.load(
      'a',
      decode: () => oldDecode.future,
      cache: (_) async {
        writes++;
      },
    );
    final failed = expectLater(old, throwsException);
    loader.cancel();
    final freshOriginal = await makeImage();
    final fresh = await loader.load(
      'a',
      decode: () async => freshOriginal,
      cache: (_) async {
        writes++;
      },
    );
    final oldOriginal = await makeImage();
    oldDecode.complete(oldOriginal);
    await failed;
    expect(oldOriginal.debugDisposed, isTrue);
    expect(writes, 1);
    fresh.dispose();
  });

  test('写盘期间取消不破坏已交付图或缓存clone', () async {
    final loader = StickerThumbnailFirstFrameLoader();
    final write = Completer<void>();
    final original = await makeImage();
    final image = await loader.load(
      'a',
      decode: () async => original,
      cache: (_) => write.future,
    );
    loader.cancel();
    expect(image.debugDisposed, isFalse);
    write.complete();
    await Future<void>.delayed(Duration.zero);
    expect(original.debugDisposed, isTrue);
    image.dispose();
  });
}
