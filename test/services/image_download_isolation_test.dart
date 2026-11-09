import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/dio_http_client.dart';

/// 响应头立即返回，响应体保持未完成，模拟慢大图占用下载槽。
class _SlowImages implements HttpClientAdapter {
  final started = <String, Completer<void>>{};
  final bodies = <String, Completer<void>>{};
  int active = 0;
  int peak = 0;

  Future<void> waitFor(String url) =>
      started.putIfAbsent(url, Completer<void>.new).future;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    active++;
    if (active > peak) peak = active;
    started.putIfAbsent(options.path, Completer<void>.new).complete();
    return ResponseBody(_body(options.path), 200);
  }

  Stream<Uint8List> _body(String url) async* {
    try {
      yield Uint8List.fromList([1]);
      final gate = bodies[url];
      if (gate != null) await gate.future;
      yield Uint8List.fromList([2, 3]);
    } finally {
      active--;
    }
  }

  void unblock() {
    for (final gate in bodies.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _SlowImages adapter;
  final downloads = <Future<Uint8List>>[];

  Future<Uint8List> fetch(
    String bucket,
    String name, {
    bool blocked = false,
    DownloadPriority priority = DownloadPriority.normal,
    String extension = 'png',
  }) {
    final url = 'https://cdn.example.com/$name.$extension';
    if (blocked) adapter.bodies[url] = Completer<void>();
    final result = BlobImageCache.fetch(bucket, url, priority: priority);
    downloads.add(result);
    return result;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('image-isolation-');
    adapter = _SlowImages();
    final dio = Dio()..httpClientAdapter = adapter;
    await BlobImageCache.configureForTesting(
      root: root,
      client: DioHttpClient.withClients(dio, dio),
    );
  });

  tearDown(() async {
    adapter.unblock();
    await Future.wait(downloads);
    downloads.clear();
    await BlobImageCache.configureForTesting();
    await root.delete(recursive: true);
  });

  test('正文慢响应体占满后台槽时，头像无需等待正文完成', () async {
    for (var i = 0; i < 5; i++) {
      fetch(BlobImageCache.contentBucket, 'content$i', blocked: true);
    }
    await Future.wait([
      for (var i = 0; i < 5; i++)
        adapter.waitFor('https://cdn.example.com/content$i.png'),
    ]).timeout(const Duration(seconds: 5));

    final avatar = fetch(BlobImageCache.avatarBucket, 'avatar');
    expect(await avatar.timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(adapter.bodies.values.every((gate) => !gate.isCompleted), isTrue);
  });

  test('慢头像占满组内 6 槽时，表情和正文仍能完成', () async {
    for (var i = 0; i < 6; i++) {
      fetch(BlobImageCache.avatarBucket, 'avatar$i', blocked: true);
    }
    await Future.wait([
      for (var i = 0; i < 6; i++)
        adapter.waitFor('https://cdn.example.com/avatar$i.png'),
    ]).timeout(const Duration(seconds: 5));
    await Future.wait([
      fetch(BlobImageCache.emojiBucket, 'emoji'),
      fetch(BlobImageCache.contentBucket, 'content'),
    ]).timeout(const Duration(seconds: 2));
    expect(adapter.bodies.values.every((gate) => !gate.isCompleted), isTrue);
  });

  test('各类全部高优请求仍受各自上限约束，总在途任务不超过 21', () async {
    const groups = [
      (BlobImageCache.avatarBucket, 6, 'png'),
      (BlobImageCache.avatarBucket, 2, 'gif'),
      (BlobImageCache.emojiBucket, 4, 'png'),
      (BlobImageCache.contentBucket, 6, 'png'),
      (BlobImageCache.stickerOriginalBucket, 3, 'png'),
    ];
    final admitted = <Future<void>>[];
    for (final (bucket, count, extension) in groups) {
      for (var i = 0; i < count; i++) {
        final name = '${bucket}_${extension}_$i';
        fetch(
          bucket,
          name,
          blocked: true,
          priority: DownloadPriority.high,
          extension: extension,
        );
        admitted.add(
          adapter.waitFor('https://cdn.example.com/$name.$extension'),
        );
      }
    }
    await Future.wait(admitted).timeout(const Duration(seconds: 5));
    expect(adapter.active, 21);
    for (final (bucket, _, extension) in groups) {
      fetch(
        bucket,
        '${bucket}_${extension}_overflow',
        priority: DownloadPriority.high,
        extension: extension,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (final (bucket, _, extension) in groups) {
      expect(
        adapter.started.containsKey(
          'https://cdn.example.com/${bucket}_${extension}_overflow.$extension',
        ),
        isFalse,
      );
    }
    adapter.unblock();
    await Future.wait(downloads);
    expect(adapter.peak, 21);
    expect(adapter.active, 0);
  });

  test('没有头像时，表情仍能使用全部 12 个小图槽', () async {
    for (var i = 0; i < 12; i++) {
      fetch(BlobImageCache.emojiBucket, 'emoji$i', blocked: true);
    }
    await Future.wait([
      for (var i = 0; i < 12; i++)
        adapter.waitFor('https://cdn.example.com/emoji$i.png'),
    ]).timeout(const Duration(seconds: 5));
    expect(adapter.active, 12);
  });
  test('大动图头像最多两个在途，静态头像无需等待它们完成', () async {
    for (var i = 0; i < 3; i++) {
      fetch(
        BlobImageCache.avatarBucket,
        'animated$i',
        blocked: true,
        extension: 'gif',
      );
    }
    final animated = [
      for (var i = 0; i < 3; i++) 'https://cdn.example.com/animated$i.gif',
    ];
    // 磁盘缓存查找是异步的，不保证 animated0/1 先入队；验证任意两条
    // 获准下载且第三条保持排队，才是并发隔离契约。
    await Stream.fromFutures(animated.map(adapter.waitFor))
        .take(2)
        .drain<void>()
        .timeout(const Duration(seconds: 5));
    await Future.wait([
      for (var i = 0; i < 6; i++)
        fetch(BlobImageCache.avatarBucket, 'static$i'),
    ]).timeout(const Duration(seconds: 2));
    expect(
      animated
          .where((url) => adapter.started[url]?.isCompleted ?? false)
          .length,
      2,
    );
    expect(adapter.bodies.values.every((gate) => !gate.isCompleted), isTrue);
  });
}
