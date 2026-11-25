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
    CancelToken? token,
  }) => service.translate(
    engine: engine,
    text: text,
    targetCode: 'zh-CN',
    targetName: '简体中文',
    cancelToken: token ?? CancelToken(),
  );

  test('Google 合并全部返回句子并保留输入首尾空白', () async {
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
    expect(request.queryParameters['sl'], 'auto');
    expect(request.queryParameters['tl'], 'zh-CN');
    expect(request.queryParameters['q'], 'Hello world');
    expect(request.headers.containsKey('Cookie'), isFalse);
    expect(request.headers.containsKey('Authorization'), isFalse);
  });

  test('长内容完整分段，代理对和换行均保留', () async {
    final text = '${'a' * 899}😀\n${'第二段\n' * 700}';
    final chunks = TranslationService.splitText(text, 900).toList();
    expect(chunks.join(), text);
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(900));
      expect(utf8.decode(utf8.encode(chunk)), chunk);
    }
    configure(
      (options, _) async => _json([
        [
          [options.queryParameters['q']],
        ],
      ]),
    );
    expect(await translate(text).join(), text);
    expect(
      adapter.requests.length,
      chunks.where((part) => part.trim().isNotEmpty).length,
    );
  });

  test('哔哩哔哩使用官方模型并过滤思考内容', () async {
    configure(
      (_, _) async => _json({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': '<think>思考</think>\n你好'},
          },
        ],
      }),
    );
    expect(
      await translate('Hello', engine: TranslationEngine.bilibili).join(),
      '你好',
    );
    final request = adapter.requests.single;
    expect(request.uri.host, 'index-translate.bilibili.com');
    expect(request.method, 'POST');
    expect(request.data['model'], 'Index-Translate-35B-A3B');
    expect(request.data['messages'][0]['content'], contains('Hello'));
    expect(request.data['stream'], isFalse);
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
      (_, _) async => _json({
        'choices': [
          {
            'finish_reason': 'length',
            'message': {'content': '半句'},
          },
        ],
      }),
    );
    await expectLater(
      translate('Hello', engine: TranslationEngine.bilibili),
      emitsError(
        isA<TranslationException>().having(
          (e) => e.failure,
          '原因',
          TranslationFailure.incomplete,
        ),
      ),
    );
  });

  test('遇到限流保留已经翻译的段落并报告限流', () async {
    configure(
      (_, _) async => adapter.requests.length == 1
          ? _json([
              [
                ['第一段'],
              ],
            ])
          : _json({}, status: 429),
    );
    await expectLater(
      translate('${'a' * 900}后续'),
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
      started.complete();
      await cancelFuture;
      cancelled.complete();
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    });
    final token = CancelToken();
    final result = expectLater(
      translate('a' * 2000, token: token),
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
