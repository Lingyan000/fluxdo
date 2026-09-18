import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/uploads/s3_multipart_upload.dart';
import 'package:fluxdo/services/uploads/upload_progress.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?)
  respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => respond(options, stream);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

void main() {
  test('分片阈值与官方一致', () {
    expect(S3MultipartUpload.chunkSize(1), 5 * 1024 * 1024);
    expect(S3MultipartUpload.chunkSize(100 * 1024 * 1024), 10 * 1024 * 1024);
    expect(S3MultipartUpload.chunkSize(500 * 1024 * 1024), 20 * 1024 * 1024);
  });
  for (final mode in [
    'retry',
    'put-cancel',
    'complete-cancel',
    'presign-cancel',
  ]) {
    test('进度去重与取消清理 $mode', () async {
      final dir = await Directory.systemTemp.createTemp('multipart-progress');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/small.bin')
          .writeAsBytes(List.filled(32, 1));
      final token = CancelToken();
      final actions = <String>[];
      final progress = <UploadProgress>[];
      var puts = 0;
      final control = Dio(BaseOptions(baseUrl: 'https://forum.test'));
      addTearDown(control.close);
      control.httpClientAdapter = _Adapter((o, stream) async {
        actions.add(o.path);
        expect(o.extra['noRecovery'], true);
        if (o.path.contains('abort')) {
          expect(o.cancelToken, isNot(same(token)));
          expect(o.cancelToken!.isCancelled, false);
          return _json({'success': true});
        }
        expect(o.cancelToken, same(token));
        if (o.path.contains('create-')) {
          return _json({
            'external_upload_identifier': 'external',
            'unique_identifier': 'unique',
          });
        }
        if (o.path.contains('presign')) {
          if (mode == 'presign-cancel') {
            token.cancel('取消签名');
            return Completer<ResponseBody>().future;
          }
          return _json({
            'presigned_urls': {'1': 'https://storage.test/part'},
          });
        }
        if (mode == 'complete-cancel') {
          token.cancel('取消合并');
          return Completer<ResponseBody>().future;
        }
        return _json({'id': 42});
      });
      final storage = Dio()
        ..httpClientAdapter = _Adapter((o, stream) async {
          puts++;
          expect(o.cancelToken, same(token));
          await stream!.drain<void>();
          if (mode == 'put-cancel') {
            token.cancel('取消上传');
            return Completer<ResponseBody>().future;
          }
          if (mode == 'retry' && puts == 1)
            return ResponseBody.fromString('', 503);
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'etag': ['etag'],
            },
          );
        });
      final future = S3MultipartUpload(
        control,
        storage: storage,
      ).upload(file, 'small.bin', cancelToken: token, onProgress: progress.add);
      if (mode == 'retry') {
        expect((await future)['id'], 42);
        expect(puts, 2);
        final sent = progress
            .where((p) => p.phase == UploadPhase.uploading)
            .map((p) => p.sentBytes)
            .toList();
        expect(sent, isNotEmpty);
        expect(sent.last, 32);
        expect(sent.every((n) => n >= 0 && n <= 32), true);
        expect(sent, orderedEquals([...sent]..sort()));
        expect(progress.last.phase, UploadPhase.processing);
      } else {
        await expectLater(
          future,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              '取消',
              DioExceptionType.cancel,
            ),
          ),
        );
        expect(actions.last, '/uploads/abort-multipart.json');
        expect(actions.where((a) => a.contains('create-')).length, 1);
        expect(
          actions.where((a) => a.contains('complete-')).length,
          mode == 'complete-cancel' ? 1 : 0,
        );
        expect(puts, mode == 'presign-cancel' ? 0 : 1);
      }
    });
  }

  test('预先取消不会发请求', () async {
    final token = CancelToken()..cancel();
    final control = Dio()
      ..httpClientAdapter = _Adapter((o, s) async => fail('不应发送请求'));
    await expectLater(
      S3MultipartUpload(control)
          .upload(File('/missing'), 'missing', cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          '取消',
          DioExceptionType.cancel,
        ),
      ),
    );
    control.close();
  });

  for (final fail in [false, true]) {
    test('分片字节、凭据隔离及失败清理 fail=$fail', () async {
      final dir = await Directory.systemTemp.createTemp('multipart-test');
      final file = File('${dir.path}/image.jpg');
      final bytes = Uint8List(5 * 1024 * 1024 + 7);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = i % 251;
      }
      await file.writeAsBytes(bytes);
      addTearDown(() => dir.delete(recursive: true));
      final actions = <String>[];
      final received = <int>[];
      final control = Dio(
        BaseOptions(
          baseUrl: 'https://forum.test',
          headers: {'Cookie': 'private', 'X-CSRF-Token': 'private'},
        ),
      );
      control.httpClientAdapter = _Adapter((o, s) async {
        actions.add(o.path);
        expect(o.extra['noRecovery'], true);
        expect(o.extra['skipRedirect'], true);
        if (o.path.contains('create-multipart')) {
          return _json({
            'external_upload_identifier': 'external',
            'unique_identifier': 'unique',
            'key': 'key',
          });
        }
        if (o.path.contains('batch-presign')) {
          expect(o.data['part_numbers'], [1, 2]);
          return _json({
            'presigned_urls': {
              '1': 'https://storage.test/1?signature=secret',
              '2': 'https://storage.test/2?signature=secret',
            },
          });
        }
        if (o.path.contains('complete-multipart')) {
          expect(o.data['parts'], [
            {'part_number': 1, 'etag': '"1"'},
            {'part_number': 2, 'etag': '"2"'},
          ]);
          return _json({'id': 42, 'short_url': 'upload://image'});
        }
        return _json({'success': true});
      });
      final storage = Dio()
        ..httpClientAdapter = _Adapter((o, stream) async {
          expect(
            o.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('cookie')),
          );
          expect(
            o.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('x-csrf-token')),
          );
          expect(o.followRedirects, false);
          await for (final chunk in stream!) {
            received.addAll(chunk);
          }
          if (fail) return ResponseBody.fromString('', 403);
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'etag': ['"${o.uri.path.substring(1)}"'],
            },
          );
        });
      final future = S3MultipartUpload(
        control,
        storage: storage,
      ).upload(file, 'image.jpg');
      if (fail) {
        await expectLater(future, throwsA(isA<DioException>()));
        expect(actions.last, '/uploads/abort-multipart.json');
        expect(actions, isNot(contains('/uploads/complete-multipart.json')));
      } else {
        expect((await future)['id'], 42);
        expect(received, orderedEquals(bytes));
        expect(actions.last, '/uploads/complete-multipart.json');
      }
      control.close();
    });
  }
}
