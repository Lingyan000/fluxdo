import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import 'package:fluxdo/services/network/interceptors/error_interceptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _endpoint = '/discourse-ai/summarization/t/42';
const _channel = '/discourse-ai/summaries/topic/42';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('已有摘要只通过 GET 读取缓存，不触发 POST', () async {
    await _withMessageBus((publish) async {
      final adapter = _SummaryAdapter((options) {
        expect(options.method, 'GET');
        expect(options.queryParameters, {'stream': 'true'});
        return _jsonResponse({
          'ai_topic_summary': {
            'summarized_text': 'cached summary',
            'outdated': true,
            'can_regenerate': true,
            'new_posts_since_summary': 3,
          },
        });
      });
      final summary = await _useAdapter(adapter)
          .getTopicSummary(42)
          .timeout(const Duration(seconds: 5));

      expect(adapter.methods, ['GET']);
      expect(summary!.summarizedText, 'cached summary');
      expect(summary.outdated, isTrue);
      expect(summary.canRegenerate, isTrue);
      expect(summary.newPostsSinceSummary, 3);
      expect(summary.isStreaming, isFalse);
      expect(MessageBusService().isPolling, isFalse);
    });
  });

  test('当前版本 GET 无缓存后 POST 生成并接收流式结果', () async {
    await _withMessageBus((publish) async {
      final adapter = _SummaryAdapter((options) {
        if (options.method == 'GET') return _jsonResponse({}, statusCode: 404);
        expect(options.data, {'stream': 'true'});
        publish();
        return _jsonResponse({'success': 'OK'});
      });
      final summaries = await _useAdapter(adapter)
          .watchTopicSummary(42)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(adapter.methods, ['GET', 'POST']);
      expect(summaries.map((s) => s!.summarizedText), ['partial', 'complete']);
      expect(summaries.map((s) => s!.isStreaming), [true, false]);
      expect(MessageBusService().isPolling, isFalse);
    });
  });

  test('旧版首次 GET 已订阅消息且使用流式生成，不再重复 POST', () async {
    await _withMessageBus((publish) async {
      final adapter = _SummaryAdapter((options) {
        expect(MessageBusService().isPolling, isTrue);
        expect(options.method, 'GET');
        expect(options.queryParameters, {'stream': 'true'});
        publish();
        return _jsonResponse({'success': 'OK'});
      });
      final summaries = await _useAdapter(adapter)
          .watchTopicSummary(42)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(adapter.methods, ['GET']);
      expect(summaries.map((s) => s!.summarizedText), ['partial', 'complete']);
      expect(summaries.map((s) => s!.isStreaming), [true, false]);
    });
  });

  test('强制重生成直接 POST 并携带 skip_age_check，保留流式结果', () async {
    await _withMessageBus((publish) async {
      final adapter = _SummaryAdapter((options) {
        expect(options.method, 'POST');
        expect(options.data, {'stream': 'true', 'skip_age_check': 'true'});
        publish();
        return _jsonResponse({'success': 'OK'});
      });
      final summaries = await _useAdapter(adapter)
          .watchTopicSummary(42, skipAgeCheck: true)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(adapter.methods, ['POST']);
      expect(summaries.map((s) => s!.isStreaming), [true, false]);
      expect(summaries.last!.summarizedText, 'complete');
    });
  });

  test('旧版不支持 POST 时，重生成回退 GET 并保留全部参数', () async {
    await _withMessageBus((publish) async {
      final adapter = _SummaryAdapter((options) {
        if (options.method == 'POST') return _jsonResponse({}, statusCode: 404);
        expect(options.queryParameters, {
          'stream': 'true',
          'skip_age_check': 'true',
        });
        publish();
        return _jsonResponse({'success': 'OK'});
      });
      final summary = await _useAdapter(adapter)
          .getTopicSummary(42, skipAgeCheck: true)
          .timeout(const Duration(seconds: 5));

      expect(adapter.methods, ['POST', 'GET']);
      expect(summary!.summarizedText, 'complete');
      expect(summary.isStreaming, isFalse);
    });
  });

  test('GET 无权限时返回空摘要并清理订阅，不继续 POST', () async {
    await _withMessageBus((publish) async {
      final adapter = _SummaryAdapter(
        (options) => _jsonResponse({}, statusCode: 403),
      );
      expect(
        await _useAdapter(adapter)
            .getTopicSummary(42)
            .timeout(const Duration(seconds: 5)),
        isNull,
      );
      expect(adapter.methods, ['GET']);
      expect(MessageBusService().isPolling, isFalse);
    });
  });
}

DiscourseService _useAdapter(_SummaryAdapter adapter) {
  final service = DiscourseService();
  final originalAdapter = service.dio.httpClientAdapter;
  final originalInterceptors = service.dio.interceptors.toList();
  service.dio.httpClientAdapter = adapter;
  // HTTP 错误保留原始状态码；UI 错误文案依赖 Navigator，不属于服务契约。
  service.dio.interceptors.removeWhere((item) => item is ErrorInterceptor);
  service.cookieSync.setCsrfToken('summary-test-token');
  addTearDown(() {
    service.dio.httpClientAdapter = originalAdapter;
    service.dio.interceptors
      ..clear()
      ..addAll(originalInterceptors);
    service.cookieSync.clearCsrfToken();
  });
  return service;
}

/// 在本地提供真实 MessageBus 轮询响应，不依赖线上服务或注入生产测试接口。
Future<void> _withMessageBus(Future<void> Function(void Function()) run) async {
  await HttpOverrides.runWithHttpOverrides(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bus = MessageBusService();
    final updates = Completer<List<Map<String, dynamic>>>();
    server.listen((request) async {
      try {
        final payload = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        expect(payload, contains(_channel));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(await updates.future));
        await request.response.close();
      } on HttpException {
        // 摘要结束时客户端会取消尚未返回的轮询。
      } on SocketException {
        // 清理测试服务器时连接可能已关闭。
      }
    });
    bus.configure(baseUrl: 'http://127.0.0.1:${server.port}');
    try {
      await run(() {
        updates.complete([
          for (final (index, text) in ['partial', 'complete'].indexed)
            {
              'channel': _channel,
              'message_id': index + 1,
              'data': {
                'done': index == 1,
                'ai_topic_summary': {'summarized_text': text},
              },
            },
        ]);
      });
    } finally {
      bus.stopAll();
      if (!updates.isCompleted) updates.complete([]);
      await server.close(force: true);
      bus.configure();
    }
  }, _LocalHttpOverrides());
}

class _LocalHttpOverrides extends HttpOverrides {}

ResponseBody _jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: const ['application/json'],
    },
  );
}

class _SummaryAdapter implements HttpClientAdapter {
  _SummaryAdapter(this.respond);

  final ResponseBody Function(RequestOptions) respond;
  final List<String> methods = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.uri.path, _endpoint);
    methods.add(options.method);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}
