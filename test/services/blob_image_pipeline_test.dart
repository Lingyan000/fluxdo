import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/blob_image_cache.dart';
import 'package:fluxdo/services/dio_http_client.dart';

class _Images implements HttpClientAdapter {
  int requests = 0;
  int cancelled = 0;
  final responseGates = <String, Completer<void>>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final gate = responseGates[options.path];
    if (gate != null) {
      await Future.any([
        gate.future,
        if (cancelFuture != null)
          cancelFuture.then((_) {
            cancelled++;
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            );
          }),
      ]);
    }
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bucket = BlobImageCache.contentBucket;
  const url = 'https://cdn.example.com/a.png';
  late Directory root;
  late _Images adapter;
  late DioHttpClient client;
  final gates = <Completer<void>>[];

  Future<void> configure(Future<void> Function()? beforeWrite) =>
      BlobImageCache.configureForTesting(
        root: root,
        client: client,
        beforeWrite: beforeWrite,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('blob-image-pipeline-');
    adapter = _Images();
    final dio = Dio()..httpClientAdapter = adapter;
    client = DioHttpClient.withClients(dio, dio);
    await configure(null);
  });

  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    await BlobImageCache.configureForTesting();
    await root.delete(recursive: true);
  });

  test('一个消费者取消不影响另一个，最后一个退出才取消传输', () async {
    final gate = Completer<void>();
    gates.add(gate);
    adapter.responseGates[url] = gate;
    final a = CancelToken();
    final b = CancelToken();
    final first = BlobImageCache.fetch(bucket, url, cancellation: a);
    final second = BlobImageCache.fetch(bucket, url, cancellation: b);
    final firstError = expectLater(first, throwsA(isA<DioException>()));
    final secondError = expectLater(second, throwsA(isA<DioException>()));
    while (adapter.requests == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    a.cancel();
    await firstError;
    expect(adapter.requests, 1);
    expect(adapter.cancelled, 0);
    b.cancel();
    await secondError;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(adapter.cancelled, 1);
  });

  test('显示消费者退出不取消并行保存，完成后文件仍可用', () async {
    final gate = Completer<void>();
    gates.add(gate);
    adapter.responseGates[url] = gate;
    final cancel = CancelToken();
    final viewing = BlobImageCache.fetch(bucket, url, cancellation: cancel);
    final failed = expectLater(viewing, throwsA(isA<DioException>()));
    final saving = BlobImageCache.getFile(bucket, url);
    while (adapter.requests == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancel.cancel();
    await failed;
    gate.complete();
    expect(await (await saving).readAsBytes(), [1, 2, 3]);
    expect(adapter.requests, 1);
    expect(adapter.cancelled, 0);
  });

  test('字节先返回、重复读不重下，getFile 必须等原子落盘完成', () async {
    final gate = Completer<void>();
    gates.add(gate);
    await configure(() => gate.future);
    final first = await BlobImageCache.fetch(bucket, url);
    expect(first, [1, 2, 3]);
    expect(await BlobImageCache.contains(bucket, url), isFalse);
    final again = await BlobImageCache.fetch(bucket, url);
    expect(identical(first, again), isTrue);
    expect(await BlobImageCache.read(bucket, url), first);
    var fileReady = false;
    final file = BlobImageCache.getFile(bucket, url).then((f) {
      fileReady = true;
      return f;
    });
    await Future<void>.delayed(Duration.zero);
    expect(fileReady, isFalse);
    expect(adapter.requests, 1);
    gate.complete();
    expect(await (await file).readAsBytes(), [1, 2, 3]);
  });

  test('写入失败不影响已下载图片，但文件消费者收到明确错误', () async {
    final gate = Completer<void>();
    gates.add(gate);
    await configure(() async {
      await gate.future;
      throw FileSystemException('disk full');
    });
    expect(await BlobImageCache.fetch(bucket, url), [1, 2, 3]);
    final file = BlobImageCache.getFile(bucket, url);
    final error = expectLater(file, throwsA(isA<FileSystemException>()));
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await error;
  });

  test('清缓存等待已有写入收尾，不会在清理后复活旧文件', () async {
    final gate = Completer<void>();
    gates.add(gate);
    await configure(() => gate.future);
    await BlobImageCache.fetch(bucket, url);
    final clearing = BlobImageCache.clearBucket(bucket);
    gate.complete();
    await clearing;
    expect(await BlobImageCache.read(bucket, url), isNull);
    expect(await BlobImageCache.contains(bucket, url), isFalse);
  });

  test('清理前发起、清理后完成的下载只返回字节，不写回缓存', () async {
    final gate = Completer<void>();
    gates.add(gate);
    adapter.responseGates[url] = gate;
    final download = BlobImageCache.fetch(bucket, url);
    while (adapter.requests == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await BlobImageCache.clearAll();
    gate.complete();
    expect(await download, [1, 2, 3]);
    expect(await BlobImageCache.contains(bucket, url), isFalse);
  });

  test('写盘背压期间继续占下载槽，前台仍可用保留槽', () async {
    final gate = Completer<void>();
    gates.add(gate);
    await configure(() => gate.future);
    // 两个后台写入占满预算；后面五个普通下载完成后阻塞于写入准入。
    await BlobImageCache.fetch(bucket, '$url?i=0');
    await BlobImageCache.fetch(bucket, '$url?i=1');
    final pending = [
      for (var i = 2; i < 10; i++) BlobImageCache.fetch(bucket, '$url?i=$i'),
    ];
    while (adapter.requests < 7) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(adapter.requests, 7);
    final visible = BlobImageCache.fetch(
      bucket,
      '$url?visible',
      priority: DownloadPriority.high,
    );
    while (adapter.requests < 8) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(adapter.requests, 8);
    gate.complete();
    await Future.wait([...pending, visible]);
    expect(adapter.requests, 11);
  });
}
