import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/uploads/s3_multipart_upload.dart';

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
