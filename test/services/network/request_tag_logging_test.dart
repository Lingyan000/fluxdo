import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/network/interceptors/network_log_interceptor.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';

/// `requestTag` 的诊断链路契约。
///
/// 这个键此前是「有读无写」的孤儿:只有 CfChallengeInterceptor 读它拼日志,
/// 全仓没有任何写入方,所以 CF 日志里 `tag=` 恒为 `-`。
/// 现在由高风险链路(csrf-refresh / otp-redeem / preload-home)主动标注,
/// 并进入网络日志,使排查能按链路而非仅按 URL 归因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('request_tag_log_test');
    await LogWriter.resetForTesting();
    await LogWriter.initForTesting(tempDir);
  });

  tearDown(() async {
    await LogWriter.resetForTesting();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('带 requestTag 的请求把标签写进网络日志', () async {
    final dio = _buildDio();
    await dio.get<dynamic>(
      '/session/csrf',
      options: Options(extra: {'requestTag': 'csrf-refresh'}),
    );

    final entry = await _readSingleRequestEntry();
    expect(entry['requestTag'], 'csrf-refresh');
    expect(entry['url'], 'https://linux.do/session/csrf');
  });

  test('未标注的请求不产生 requestTag 字段', () async {
    final dio = _buildDio();
    await dio.get<dynamic>('/latest.json');

    final entry = await _readSingleRequestEntry();
    expect(entry.containsKey('requestTag'), isFalse);
  });

  test('总时限记录为 call_deadline，不误记为用户主动取消', () async {
    final dio =
        DeadlineDio(
            BaseOptions(baseUrl: 'https://linux.do'),
            const Duration(milliseconds: 100),
          )
          ..httpClientAdapter = _OkAdapter(
            delay: const Duration(milliseconds: 300),
          )
          ..interceptors.add(NetworkLogInterceptor());
    await expectLater(
      dio.get<dynamic>('/latest.json'),
      throwsA(isA<DioException>()),
    );
    // 调用截止立即返回；让 Dio 的错误链完成日志落库。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final entry = await _readSingleRequestEntry();
    expect(entry['errorType'], 'call_deadline');
    expect(entry['callTimeoutMs'], 100);
    expect(entry['level'], 'warning');
    dio.close(force: true);
  });
}

Future<Map<String, dynamic>> _readSingleRequestEntry() async {
  await LogWriter.instance.flushNow();
  final file = await LogWriter.getLogFile();
  final entries = file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .where((e) => e['type'] == 'request')
      .toList();
  expect(entries, hasLength(1));
  return entries.single;
}

Dio _buildDio() {
  final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'))
    ..httpClientAdapter = _OkAdapter();
  dio.interceptors.add(NetworkLogInterceptor());
  return dio;
}

class _OkAdapter implements HttpClientAdapter {
  _OkAdapter({this.delay = Duration.zero});
  final Duration delay;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
