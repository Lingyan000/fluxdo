import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/uploads/upload_trace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('上传日志关联事件且不泄露异常内的签名地址和凭据', () async {
    final dir = await Directory.systemTemp.createTemp('upload-log');
    await LogWriter.resetForTesting();
    await LogWriter.initForTesting(dir);
    addTearDown(() async {
      await LogWriter.resetForTesting();
      await dir.delete(recursive: true);
    });
    final trace = UploadTrace();
    trace.event('multipart_start', fields: {'fileBytes': 123});
    trace.event(
      'multipart_part_failed',
      fields: {'partNumber': 1},
      error: DioException(
        requestOptions: RequestOptions(
          path: 'https://storage.test/private?signature=SECRET',
          headers: {'Cookie': 'PRIVATE_COOKIE'},
        ),
        type: DioExceptionType.sendTimeout,
        error: 'SECRET_ERROR',
      ),
    );
    await LogWriter.instance.flushNow();
    final text = await (await LogWriter.getLogFile()).readAsString();
    expect(text, isNot(contains('SECRET')));
    expect(text, isNot(contains('PRIVATE_COOKIE')));
    expect(text, isNot(contains('storage.test')));
    final events = text
        .split('\n')
        .where((s) => s.isNotEmpty)
        .map((s) => jsonDecode(s) as Map)
        .where((m) => m['type'] == 'upload')
        .toList();
    expect(events, hasLength(2));
    expect(events.map((e) => e['uploadTraceId']).toSet(), {trace.id});
    expect(events.last['errorType'], 'sendTimeout');
  });
}
