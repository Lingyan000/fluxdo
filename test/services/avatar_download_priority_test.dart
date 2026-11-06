import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/dio_http_client.dart';
import 'package:fluxdo/widgets/common/animated_avatar_overlay.dart';
import 'package:fluxdo/widgets/common/smart_avatar.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';

class _Avatars implements HttpClientAdapter {
  _Avatars(this.png);
  final Uint8List png;
  final started = <String, Completer<void>>{};
  final gates = <String, Completer<void>>{};
  int requests = 0;

  Future<void> waitFor(String url) =>
      started.putIfAbsent(url, Completer<void>.new).future;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final start = started.putIfAbsent(options.path, Completer<void>.new);
    if (!start.isCompleted) start.complete();
    await gates[options.path]?.future;
    return ResponseBody.fromBytes(png, 200);
  }

  void unblock() {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Avatars adapter;
  late Uint8List png;
  const bucket = BlobImageCache.avatarBucket;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff336699), BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('avatar-priority-');
    adapter = _Avatars(png);
    final dio = Dio()..httpClientAdapter = adapter;
    await BlobImageCache.configureForTesting(
      root: root,
      client: DioHttpClient.withClients(dio, dio),
    );
  });

  tearDown(() async {
    adapter.unblock();
    await BlobImageCache.configureForTesting();
    await root.delete(recursive: true);
  });

  Future<void> waitUntil(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('头像未在测试时限内完成');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  for (final keepVisible in [true, false]) {
    testWidgets(
      keepVisible ? '可见头像越过后台预热队列，另一视图离开不撤销优先权，重访同步命中' : '最后一个视图离开后撤销头像优先权',
      (tester) async {
        await tester.runAsync(() async {
          final prefix = 'https://cdn.example.com/priority-$keepVisible/';
          final active = [for (var i = 0; i < 6; i++) '${prefix}active$i.png'];
          final background = '${prefix}background.png';
          final visible = '${prefix}visible.png';
          final all = [...active, background, visible];
          final first = RenderConstrainedBox(
            additionalConstraints: const BoxConstraints(),
          );
          final second = RenderConstrainedBox(
            additionalConstraints: const BoxConstraints(),
          );
          for (final url in all) {
            adapter.gates[url] = Completer<void>();
          }
          try {
            for (final url in active) {
              TopicCardImages.prewarm(url);
            }
            await Future.wait(active.map(adapter.waitFor))
                .timeout(const Duration(seconds: 5));
            TopicCardImages.prewarm(background);
            TopicCardImages.prewarm(visible);
            await Future<void>.delayed(const Duration(milliseconds: 30));
            expect(TopicCardImages.lookup(visible, first), isNull);
            expect(TopicCardImages.lookup(visible, second), isNull);
            TopicCardImages.releaseRequester(first);
            if (!keepVisible) TopicCardImages.releaseRequester(second);
            adapter.gates[active.first]!.complete();
            final expected = keepVisible ? visible : background;
            final waiting = keepVisible ? background : visible;
            await adapter.waitFor(expected).timeout(const Duration(seconds: 2));
            expect(adapter.started[waiting]?.isCompleted ?? false, isFalse);
          } finally {
            adapter.unblock();
            await waitUntil(
              () => all.every(
                (url) => TopicCardImages.lookup(url, second) != null,
              ),
            );
            TopicCardImages.releaseRequester(first);
            TopicCardImages.releaseRequester(second);
            first.dispose();
            second.dispose();
          }
          final requests = adapter.requests;
          final cacheReader = RenderConstrainedBox(
            additionalConstraints: const BoxConstraints(),
          );
          final cached = TopicCardImages.lookup(visible, cacheReader);
          expect(cached, isNotNull);
          cacheReader.dispose();
          expect(adapter.requests, requests);
        });
      },
    );
  }

  testWidgets('动图头像组件与自绘首帧共享头像下载和磁盘缓存', (tester) async {
    const url = 'https://cdn.example.com/shared-animated-avatar.gif';
    await tester.runAsync(() async {
      adapter.gates[url] = Completer<void>();
      final requester = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints(),
      );
      try {
        // 网络闸门和共享下载都在真实 IO 区域创建，避免混用假时钟的
        // Completer，导致等待文件时还必须手动 pump 才能释放响应。
        TopicCardImages.prewarm(url);
        await adapter.waitFor(url).timeout(const Duration(seconds: 5));
        await tester.pumpWidget(
          const MaterialApp(
            home: Row(
              children: [
                SmartAvatar(imageUrl: url, radius: 20),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: AnimatedAvatarOverlay(url: url),
                ),
              ],
            ),
          ),
        );
        await adapter.waitFor(url).timeout(const Duration(seconds: 5));
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
        adapter.unblock();
        await BlobImageCache.getFile(
          bucket,
          url,
        ).timeout(const Duration(seconds: 5));
        expect(adapter.requests, 1);
        expect(await BlobImageCache.contains(bucket, url), isTrue);
        expect(
          await BlobImageCache.contains(BlobImageCache.contentBucket, url),
          isFalse,
        );
      } finally {
        adapter.unblock();
        await tester.pumpWidget(const SizedBox.shrink());
        await waitUntil(() => TopicCardImages.lookup(url, requester) != null);
        TopicCardImages.releaseRequester(requester);
        requester.dispose();
      }
    });
  });
}
