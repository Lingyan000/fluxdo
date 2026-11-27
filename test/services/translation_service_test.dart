import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/translation_engine.dart';
import 'package:fluxdo/services/translation_service.dart';

class _TranslationAdapter implements HttpClientAdapter {
  _TranslationAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions, Future<void>?) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _sse(List<String> lines, {int status = 200}) =>
    ResponseBody.fromString(
      '${lines.join('\n')}\n',
      status,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream; charset=utf-8'],
      },
    );

ResponseBody _html(String html, {int status = 200}) => ResponseBody.fromString(
  html,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

String _extractGoogleQuery(RequestOptions options) {
  final data = options.data;
  if (data is Map && data['q'] is String) return data['q'] as String;
  if (data is String) {
    return Uri.splitQueryString(data)['q'] ?? '';
  }
  return options.queryParameters['q']?.toString() ?? '';
}

void main() {
  late TranslationService service;
  late _TranslationAdapter adapter;
  void configure(
    Future<ResponseBody> Function(RequestOptions, Future<void>?) handler,
  ) {
    adapter = _TranslationAdapter(handler);
    service = TranslationService(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(service.dispose);
  }

  Stream<String> translate(
    String text, {
    TranslationEngine engine = TranslationEngine.google,
    String targetCode = 'zh-CN',
    String targetName = '简体中文',
    CancelToken? token,
  }) => service.translate(
    engine: engine,
    text: text,
    targetCode: targetCode,
    targetName: targetName,
    cancelToken: token ?? CancelToken(),
  );

  test('Google 走 POST 大批次合并全部返回句子并保留输入首尾空白', () async {
    configure(
      (_, _) async => _json([
        [
          ['你好', 'Hello'],
          ['世界', 'world'],
        ],
        null,
        'en',
      ]),
    );
    expect(await translate('  Hello world\n').join(), '  你好世界\n');
    final request = adapter.requests.single;
    expect(request.uri.host, 'translate.googleapis.com');
    expect(request.method, 'POST');
    expect(request.queryParameters['sl'], 'auto');
    expect(request.queryParameters['tl'], 'zh-CN');
    expect(_extractGoogleQuery(request), 'Hello world');
    expect(request.headers.containsKey('Cookie'), isFalse);
    expect(request.headers.containsKey('Authorization'), isFalse);
  });

  test('长内容完整分段并并发翻译、保序输出，代理对和换行均保留', () async {
    final text = '${'a' * 2599}😀\n${'第二段\n' * 1500}';
    final chunks = TranslationService.splitText(text, 2600).toList();
    expect(chunks.length, greaterThan(1));
    expect(chunks.join(), text);
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(2600));
      expect(utf8.decode(utf8.encode(chunk)), chunk);
    }
    configure(
      (options, _) async => _json([
        [
          [_extractGoogleQuery(options)],
        ],
      ]),
    );
    expect(await translate(text).join(), text);
    expect(
      adapter.requests.length,
      chunks.where((part) => part.trim().isNotEmpty).length,
    );
  });

  test('微软必应翻译自动获取并缓存令牌、映射语言代码，且过期后自动刷新重试', () async {
    var authCalls = 0;
    var translateCalls = 0;
    configure((options, _) async {
      if (options.uri.path == '/translator') {
        authCalls++;
        return _html(
          '<html><script>IG:"IG_$authCalls";var params_AbusePreventionHelper = [123456, "TOK_$authCalls", 3600000];</script><div data-iid="translator.5025"></div></html>',
        );
      }
      translateCalls++;
      // 首次翻译模拟令牌失效返回 statusCode=205，触发自动刷新重试。
      if (translateCalls == 1) {
        return _json({'statusCode': 205, 'errorMessage': ''});
      }
      final body = options.data as Map;
      expect(body['to'], 'zh-Hans');
      expect(body['token'], 'TOK_2');
      return _json([
        {
          'translations': [
            {'text': '你好世界', 'to': 'zh-Hans'},
          ],
        },
      ]);
    });

    expect(
      await translate('Hello world', engine: TranslationEngine.bing).join(),
      '你好世界',
    );
    expect(authCalls, 2);
    expect(translateCalls, 2);

    // 二次翻译直接复用已缓存令牌，不再拉取首页。
    expect(
      await translate('Hello again', engine: TranslationEngine.bing).join(),
      '你好世界',
    );
    expect(authCalls, 2);
    expect(translateCalls, 3);
  });

  test('哔哩哔哩开启 SSE 流式输出并实时过滤思考前缀', () async {
    configure(
      (_, _) async => _sse([
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '<think>先思考'},
              'finish_reason': null,
            },
          ],
        })}',
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '</think>\n你好'},
              'finish_reason': null,
            },
          ],
        })}',
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '，世界'},
              'finish_reason': 'stop',
            },
          ],
        })}',
        'data: [DONE]',
      ]),
    );
    final chunks = await translate(
      'Hello',
      engine: TranslationEngine.bilibili,
    ).toList();
    expect(chunks, ['你好', '，世界']);
    final request = adapter.requests.single;
    expect(request.uri.host, 'index-translate.bilibili.com');
    expect(request.method, 'POST');
    expect(request.data['model'], 'Index-Translate-35B-A3B');
    expect(request.data['messages'][0]['content'], contains('Hello'));
    expect(request.data['stream'], isTrue);
  });

  test('长段落优先在单词间断开', () {
    final parts = TranslationService.splitText(
      'hello world hello world',
      9,
    ).toList();
    expect(parts, ['hello ', 'world ', 'hello ', 'world']);
  });

  test('不完整的哔哩哔哩返回提示重试，不能当作成功', () async {
    configure(
      (_, _) async => _sse([
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '半句'},
              'finish_reason': 'length',
            },
          ],
        })}',
        'data: [DONE]',
      ]),
    );
    await expectLater(
      translate('Hello', engine: TranslationEngine.bilibili),
      emitsInOrder([
        '半句',
        emitsError(
          isA<TranslationException>().having(
            (e) => e.failure,
            '原因',
            TranslationFailure.incomplete,
          ),
        ),
      ]),
    );
  });

  test('遇到限流保留已经翻译的段落并报告限流', () async {
    configure(
      (options, _) async => _extractGoogleQuery(options).startsWith('aaaa')
          ? _json([
              [
                ['第一段'],
              ],
            ])
          : _json({}, status: 429),
    );
    await expectLater(
      translate('${'a' * 2600}后续'),
      emitsInOrder([
        '第一段',
        emitsError(
          isA<TranslationException>().having(
            (e) => e.failure,
            '原因',
            TranslationFailure.rateLimited,
          ),
        ),
      ]),
    );
  });

  test('取消会传递到网络请求并阻止后续分段', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    configure((options, cancelFuture) async {
      if (!started.isCompleted) started.complete();
      await cancelFuture;
      if (!cancelled.isCompleted) cancelled.complete();
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    });
    final token = CancelToken();
    final result = expectLater(
      translate('a' * 100, token: token),
      emitsError(
        isA<DioException>().having(
          (e) => e.type,
          '类型',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;
    token.cancel();
    await result;
    await cancelled.future;
    expect(adapter.requests, hasLength(1));
  });
}
