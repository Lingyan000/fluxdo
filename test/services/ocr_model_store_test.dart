import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/ocr/ocr_model_store.dart';
import 'package:path/path.dart' as p;

class _ModelAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  late FutureOr<ResponseBody> Function(RequestOptions, Future<void>?) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late OcrModelStore store;
  late _ModelAdapter adapter;
  final model = [1, 2, 3, 4, 5, 6], config = [10, 20, 30];
  final archive = TarEncoder().encodeBytes(
    Archive()
      ..addFile(ArchiveFile.bytes('rec_infer/rec.tflite', model))
      ..addFile(ArchiveFile.bytes('rec_infer/rec.yml', config))
      ..addFile(ArchiveFile.string('rec_infer/README.md', '说明')),
  );
  String digest(List<int> bytes) => sha256.convert(bytes).toString();
  final bundle = OcrModelBundle(
    baseUrl: 'https://modelscope.cn/models/fluxdo/test/resolve/pinned/',
    archiveBaseUrl: 'https://backup.example/ocr/',
    archiveName: 'rec_infer',
    archiveSize: archive.length,
    archiveSha: digest(archive),
    files: [
      OcrModelFile('rec.tflite', 'rec.tflite', model.length, digest(model)),
      OcrModelFile('rec.yml', 'rec.yml', config.length, digest(config)),
    ],
  );
  ResponseBody direct(RequestOptions request) => ResponseBody.fromBytes(
    request.uri.path.endsWith('.tflite') ? model : config,
    200,
  );
  File local(String name) => File(p.join(directory.path, name));
  Future<void> download({
    CancelToken? token,
    void Function(double)? progress,
  }) => store.download(
    cancelToken: token ?? CancelToken(),
    onProgress: progress ?? (_) {},
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluxdo-ocr-test-');
    adapter = _ModelAdapter()..respond = (request, _) => direct(request);
    store = OcrModelStore(
      dio: Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
      bundles: [bundle],
    );
  });
  tearDown(() async {
    store.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('缓存按 SHA 校验，主源仅补齐损坏文件，后续使用不再联网', () async {
    await local('rec.tflite').writeAsBytes(model.reversed.toList());
    await local('rec.yml').writeAsBytes(config);
    expect(await store.isReady(), isFalse);
    await download();
    expect(await store.isReady(), isTrue);
    await download();
    expect(adapter.requests.map((r) => r.uri.toString()), [
      bundle.url(bundle.files.first),
    ]);
  });

  test('主源中断后用一个备用包补齐模型和同一份字典，清理各自的断点', () async {
    await local('rec_infer.tar.part').writeAsBytes(archive.take(5).toList());
    adapter.respond = (request, _) {
      if (request.uri.toString() == bundle.archiveUrl) {
        expect(request.headers[HttpHeaders.rangeHeader], 'bytes=5-');
        return ResponseBody.fromBytes(
          archive.sublist(5),
          206,
          headers: {
            HttpHeaders.contentRangeHeader: [
              'bytes 5-${archive.length - 1}/${archive.length}',
            ],
          },
        );
      }
      Stream<Uint8List> interrupted() async* {
        yield Uint8List.fromList([1, 2]);
        throw const SocketException('连接中断');
      }

      return ResponseBody(interrupted(), 200);
    };
    final progress = <double>[];
    await download(progress: progress.add);
    expect(progress, orderedEquals([...progress]..sort()));
    expect(progress.last, 1);
    expect(await store.isReady(), isTrue);
    expect(
      await directory.list().map((f) => p.basename(f.path)).toList(),
      unorderedEquals(['rec.tflite', 'rec.yml']),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('主源只续传缺失的字节；服务器忽略 Range 时可以从头覆盖', () async {
    for (final range in [true, false]) {
      if (await local('rec.tflite').exists()) {
        await local('rec.tflite').delete();
      }
      await local('rec.tflite.part').writeAsBytes(model.take(2).toList());
      adapter.respond = (request, _) {
        if (!request.uri.path.endsWith('.tflite')) return direct(request);
        expect(request.headers[HttpHeaders.rangeHeader], 'bytes=2-');
        return range
            ? ResponseBody.fromBytes(
                model.sublist(2),
                206,
                headers: {
                  HttpHeaders.contentRangeHeader: ['bytes 2-5/6'],
                },
              )
            : direct(request);
      };
      await download();
      expect(await store.isReady(), isTrue);
      expect(await local('rec.tflite.part').exists(), isFalse);
    }
  });

  test('已经下载的识别模型保留，只有字典缺失时也能从备用包恢复', () async {
    await local('rec.tflite').writeAsBytes(model);
    adapter.respond = (request, _) => request.uri.host == 'modelscope.cn'
        ? ResponseBody.fromBytes([30, 20, 10], 200)
        : ResponseBody.fromBytes(archive, 200);
    await download();
    expect(await store.isReady(), isTrue);
    expect(adapter.requests.map((r) => r.uri.toString()), [
      bundle.url(bundle.files.last),
      bundle.archiveUrl,
    ]);
  });

  test('两个渠道都返回损坏文件时清理残片，允许重试', () async {
    adapter.respond = (request, _) => ResponseBody.fromBytes(
      List.filled(
        request.uri.host == 'modelscope.cn' ? model.length : archive.length,
        99,
      ),
      200,
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(download(), throwsFormatException);
      expect(await directory.list().toList(), isEmpty);
      expect(await store.isReady(), isFalse);
    }
    expect(adapter.requests, hasLength(4));
  });

  test('上次正文提前结束而备用源不可用时，下次从实际写入的字节继续', () async {
    adapter.respond = (request, _) => request.uri.host == 'modelscope.cn'
        ? ResponseBody.fromBytes(model.sublist(0, 2), 200)
        : ResponseBody.fromString('', 503);
    await expectLater(download(), throwsA(isA<DioException>()));
    expect(await local('rec.tflite.part').readAsBytes(), model.sublist(0, 2));
    adapter.respond = (request, _) {
      if (!request.uri.path.endsWith('.tflite')) return direct(request);
      expect(request.headers[HttpHeaders.rangeHeader], 'bytes=2-');
      return ResponseBody.fromBytes(
        model.sublist(2),
        206,
        headers: {
          HttpHeaders.contentRangeHeader: ['bytes 2-5/6'],
        },
      );
    };
    await download();
    expect(await store.isReady(), isTrue);
    expect(await local('rec.tflite.part').exists(), isFalse);
  });

  test('首个面板取消时不触发备用下载，排队的面板可以继续', () async {
    final started = Completer<void>();
    adapter.respond = (request, cancelFuture) async {
      if (!started.isCompleted) {
        started.complete();
        await cancelFuture;
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.cancel,
        );
      }
      return direct(request);
    };
    final token = CancelToken();
    final first = expectLater(
      download(token: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          '类型',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;
    final second = download();
    token.cancel();
    await Future.wait([first, second]);
    expect(await store.isReady(), isTrue);
    expect(
      adapter.requests.every((r) => r.uri.host == 'modelscope.cn'),
      isTrue,
    );
    expect(adapter.requests, hasLength(3));
  });

  test('支持查询已下载模型大小并彻底删除释放空间', () async {
    expect(await store.installedBytes(), 0);
    await download();
    expect(await store.installedBytes(), model.length + config.length);
    expect(await store.isReady(), isTrue);

    await store.clear();
    expect(await store.installedBytes(), 0);
    expect(await store.isReady(), isFalse);
  });

  test('未配置项目模型源时不请求其他人的服务，已安装模型仍可离线使用', () async {
    store.dispose();
    store = OcrModelStore(
      dio: Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
      bundles: [
        OcrModelBundle(
          baseUrl: '',
          archiveName: bundle.archiveName,
          archiveSize: bundle.archiveSize,
          archiveSha: bundle.archiveSha,
          files: bundle.files,
        ),
      ],
    );
    await expectLater(download(), throwsStateError);
    expect(adapter.requests, isEmpty);
    await local('rec.tflite').writeAsBytes(model);
    await local('rec.yml').writeAsBytes(config);
    await download();
    expect(await store.isReady(), isTrue);
    expect(adapter.requests, isEmpty);
  });

  test('没有备用源时保留主源断点并报告原错误', () async {
    store.dispose();
    store = OcrModelStore(
      dio: Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
      bundles: [
        OcrModelBundle(
          baseUrl: bundle.baseUrl,
          archiveName: bundle.archiveName,
          archiveSize: bundle.archiveSize,
          archiveSha: bundle.archiveSha,
          files: bundle.files,
        ),
      ],
    );
    adapter.respond = (_, _) =>
        ResponseBody.fromBytes(model.sublist(0, 2), 200);
    await expectLater(download(), throwsA(isA<HttpException>()));
    expect(adapter.requests, hasLength(1));
    expect(await local('rec.tflite.part').readAsBytes(), model.sublist(0, 2));
  });
}
