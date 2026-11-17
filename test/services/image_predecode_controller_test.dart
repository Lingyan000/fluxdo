import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/image_predecode_controller.dart';

class _CountedImage extends MemoryImage {
  _CountedImage(super.bytes);
  final _loads = [0];
  int get loads => _loads.single;
  @override
  ImageStreamCompleter loadImage(MemoryImage key, ImageDecoderCallback decode) {
    _loads[0]++;
    return super.loadImage(key, decode);
  }
}

void main() {
  final staticBytes = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  );
  final animatedBytes = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAAh+QQBAAAAACwAAAAAAQABAAACAUQAOw==',
  );

  testWidgets('静态邻图预解码与当前图共享缓存，完成后释放监听', (tester) async {
    final controller = ImagePredecodeController();
    addTearDown(controller.dispose);
    final source = _CountedImage(staticBytes);
    final provider = ResizeImage(
      source,
      width: 16,
      height: 16,
      policy: ResizeImagePolicy.fit,
    );
    await tester.runAsync(() async {
      await controller.prefetch(
        provider: provider,
        loadBytes: () async => staticBytes,
        configuration: ImageConfiguration.empty,
      );
      expect(source.loads, 1);
      final ready = Completer<void>();
      final stream = provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, _) {
          info.dispose();
          ready.complete();
        },
        onError: (Object error, StackTrace? stack) =>
            ready.completeError(error, stack),
      );
      stream.addListener(listener);
      await ready.future;
      stream.removeListener(listener);
      await Future<void>.delayed(Duration.zero);
      expect(source.loads, 1);
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final status = tester.binding.imageCache.statusForKey(key);
      expect(status.keepAlive, isTrue);
      expect(status.live, isFalse);
      tester.binding.imageCache.evict(key);
    });
  });

  testWidgets('跳过多帧图片和超预算原图，不为缩略尺寸提前解码大图', (tester) async {
    final controller = ImagePredecodeController();
    addTearDown(controller.dispose);
    final cache = tester.binding.imageCache;
    final savedBudget = cache.maximumSizeBytes;
    addTearDown(() => cache.maximumSizeBytes = savedBudget);
    await tester.runAsync(() async {
      final buffer = await ui.ImmutableBuffer.fromUint8List(animatedBytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      expect(codec.frameCount, 2);
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      // PNG 压缩字节很小，原始像素超预算；覆盖先读取元数据再拒绝的路径。
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawPaint(ui.Paint()..color = const ui.Color(0xff4488aa));
      final picture = recorder.endRecording();
      final image = await picture.toImage(128, 128);
      final large = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      picture.dispose();
      for (final bytes in [animatedBytes, large]) {
        cache.maximumSizeBytes = 32 * 1024;
        final source = _CountedImage(bytes);
        await controller.prefetch(
          provider: ResizeImage(
            source,
            width: 1,
            height: 1,
            policy: ResizeImagePolicy.fit,
          ),
          loadBytes: () async => bytes,
          configuration: ImageConfiguration.empty,
        );
        expect(source.loads, 0);
      }
    });
  });

  for (final dispose in [false, true]) {
    testWidgets('加载迟到时失效的预解码不再启动 dispose=$dispose', (tester) async {
      final controller = ImagePredecodeController();
      addTearDown(controller.dispose);
      final source = _CountedImage(staticBytes);
      final bytes = Completer<Uint8List>();
      final pending = controller.prefetch(
        provider: ResizeImage(source, width: 16, policy: ResizeImagePolicy.fit),
        loadBytes: () => bytes.future,
        configuration: ImageConfiguration.empty,
      );
      if (dispose) {
        controller.dispose();
      } else {
        controller.cancel();
      }
      bytes.complete(staticBytes);
      await pending;
      expect(source.loads, 0);
    });
  }
}
