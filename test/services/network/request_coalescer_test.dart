import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/deadline_dio.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/network/recovery/policies.dart';
import 'package:fluxdo/services/network/recovery/recovery_coordinator.dart';
import 'package:fluxdo/services/network/request_coalescer.dart';

class _ControlledAdapter implements HttpClientAdapter {
  _ControlledAdapter(this._onFetch);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )
  _onFetch;

  int callCount = 0;
  final List<RequestOptions> seenOptions = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    callCount++;
    seenOptions.add(options);
    return _onFetch(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

Options _coalesceOptions({
  Map<String, dynamic>? headers,
  Map<String, dynamic>? extra,
  ResponseType? responseType,
}) => Options(
  headers: headers,
  responseType: responseType,
  extra: {FluxRequestKeys.allowCoalescing: true, ...?extra},
);

DeadlineDio _createDio(
  HttpClientAdapter adapter, {
  RequestCoalescer? coalescer,
  Duration? callTimeout = const Duration(seconds: 5),
}) {
  final dio = DeadlineDio(
    BaseOptions(
      baseUrl: 'https://linux.do',
      followRedirects: false,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 400,
    ),
    callTimeout,
    coalescer ?? RequestCoalescer(sessionGenerationProvider: () => 1),
  );
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  group('RequestCoalescer', () {
    test('默认关闭（Opt-In）：未显式开启的并发 GET 各自独立发出，保障实时刷新', () async {
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();
      var seq = 0;
      final adapter = _ControlledAdapter((options, _) async {
        final current = ++seq;
        if (current == 1) {
          await gate1.future;
          return ResponseBody.fromString(
            '{"likes":1}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        await gate2.future;
        return ResponseBody.fromString(
          '{"likes":2}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      final coalescer = RequestCoalescer(sessionGenerationProvider: () => 1);
      final dio = _createDio(adapter, coalescer: coalescer);
      addTearDown(() => dio.close(force: true));

      final r1 = dio.get<Map<String, dynamic>>('/posts/123.json');
      final r2 = dio.get<Map<String, dynamic>>('/posts/123.json');
      await pumpEventQueue();

      expect(adapter.callCount, 2);
      expect(coalescer.activeFlightCount, 0);

      gate1.complete();
      gate2.complete();
      final results = await Future.wait([r1, r2]);
      expect(results[0].data?['likes'], 1);
      expect(results[1].data?['likes'], 2);
    });

    test('显式 allowCoalescing 的并发相同 GET 合并为单次请求，且响应数据互相隔离', () async {
      final gate = Completer<void>();
      final adapter = _ControlledAdapter((options, _) async {
        await gate.future;
        return ResponseBody.fromString(
          '{"notifications":[{"id":1},{"id":2}]}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        );
      });
      final coalescer = RequestCoalescer(sessionGenerationProvider: () => 1);
      final dio = _createDio(adapter, coalescer: coalescer);
      addTearDown(() => dio.close(force: true));

      final f1 = dio.get<Map<String, dynamic>>(
        '/notifications',
        queryParameters: {'a': '1', 'b': '2'},
        options: _coalesceOptions(),
      );
      final f2 = dio.get<Map<String, dynamic>>(
        '/notifications',
        // 查询参数顺序不同也应归一化命中同一在途请求
        queryParameters: {'b': '2', 'a': '1'},
        options: _coalesceOptions(),
      );

      await pumpEventQueue();
      expect(adapter.callCount, 1);
      expect(coalescer.activeFlightCount, 1);

      gate.complete();
      final results = await Future.wait([f1, f2]);
      expect(coalescer.activeFlightCount, 0);

      final r1 = results[0];
      final r2 = results[1];
      expect(r1.statusCode, 200);
      expect(r2.statusCode, 200);
      expect(r1.extra[RequestCoalescer.coalescedResponseExtraKey], isNull);
      expect(r2.extra[RequestCoalescer.coalescedResponseExtraKey], isTrue);

      // 修改领导者返回的 JSON Map/List，不应污染跟随者的副本
      (r1.data!['notifications'] as List).clear();
      expect((r2.data!['notifications'] as List), hasLength(2));

      // 完成后立即移除，后续顺序请求应正常发起新的网络请求（不做结果缓存）
      final r3 = await dio.get<Map<String, dynamic>>(
        '/notifications',
        queryParameters: {'a': '1', 'b': '2'},
        options: _coalesceOptions(),
      );
      expect(adapter.callCount, 2);
      expect((r3.data!['notifications'] as List), hasLength(2));
    });

    test('写屏障：写请求发起前后均摘除在途 GET，写后读绝不搭车写前快照且不取消旧 GET', () async {
      final getBeforeGate = Completer<void>();
      final putGate = Completer<void>();
      final getDuringPutGate = Completer<void>();
      final getAfterPutGate = Completer<void>();
      var getSeq = 0;

      final adapter = _ControlledAdapter((options, _) async {
        if (options.method == 'PUT') {
          await putGate.future;
          return ResponseBody.fromString(
            '{"success":"OK"}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        final current = ++getSeq;
        if (current == 1) {
          await getBeforeGate.future;
          return ResponseBody.fromString(
            '{"unread":3}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        if (current == 2) {
          await getDuringPutGate.future;
          return ResponseBody.fromString(
            '{"unread":2}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        await getAfterPutGate.future;
        return ResponseBody.fromString(
          '{"unread":0}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      final coalescer = RequestCoalescer(sessionGenerationProvider: () => 1);
      final dio = _createDio(adapter, coalescer: coalescer);
      addTearDown(() => dio.close(force: true));

      // 1) 写前发起一个允许合并的 GET（仍在途）
      final getBefore = dio.get<Map<String, dynamic>>(
        '/notifications',
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(getSeq, 1);
      expect(coalescer.activeFlightCount, 1);

      // 2) 发起 PUT 写操作：写屏障摘除 getBefore，但不取消 getBefore
      final putFuture = dio.put<Map<String, dynamic>>(
        '/notifications/mark-read',
      );
      await pumpEventQueue();
      expect(coalescer.activeFlightCount, 0);

      // 3) PUT 仍在进行期间来了新的 GET：必须发新请求，不得搭车写前的 getBefore
      final getDuringPut = dio.get<Map<String, dynamic>>(
        '/notifications',
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(getSeq, 2);

      // 4) PUT 完成：再次触发写屏障，摘除在 PUT 期间发出的 getDuringPut
      putGate.complete();
      await putFuture;
      expect(coalescer.activeFlightCount, 0);

      // 5) PUT 完成后立刻刷新 GET：必须发第 3 次请求拿到最新状态，绝不搭车 getDuringPut
      final getAfterPut = dio.get<Map<String, dynamic>>(
        '/notifications',
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(getSeq, 3);

      getBeforeGate.complete();
      getDuringPutGate.complete();
      getAfterPutGate.complete();

      final results = await Future.wait([getBefore, getDuringPut, getAfterPut]);
      expect(results[0].data?['unread'], 3);
      expect(results[1].data?['unread'], 2);
      expect(results[2].data?['unread'], 0);
    });

    test('不同请求头、不同 responseType、POST、stream 及特殊豁免标记均不合并', () async {
      final gate = Completer<void>();
      final adapter = _ControlledAdapter((options, _) async {
        await gate.future;
        return ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      final dio = _createDio(adapter);
      addTearDown(() => dio.close(force: true));

      final futures = <Future<dynamic>>[
        dio.get<Map<String, dynamic>>('/t/1.json', options: _coalesceOptions()),
        // 不同 Accept 头
        dio.get<Map<String, dynamic>>(
          '/t/1.json',
          options: _coalesceOptions(headers: {'Accept': 'text/plain'}),
        ),
        // String 泛型会自动归一化为 ResponseType.plain
        dio.get<String>('/t/1.json', options: _coalesceOptions()),
        // POST 写操作不合并（即使带了 allowCoalescing）
        dio.post<dynamic>('/t/1.json', options: _coalesceOptions()),
        // skipRedirect / skipSessionStateSync / stream 不合并
        dio.get<Map<String, dynamic>>(
          '/t/1.json',
          options: _coalesceOptions(
            extra: {FluxRequestKeys.skipRedirect: true},
          ),
        ),
        dio.get<Map<String, dynamic>>(
          '/t/1.json',
          options: _coalesceOptions(
            extra: {FluxRequestKeys.skipSessionStateSync: true},
          ),
        ),
        dio.get<ResponseBody>(
          '/t/1.json',
          options: _coalesceOptions(responseType: ResponseType.stream),
        ),
      ];

      await pumpEventQueue();
      expect(adapter.callCount, futures.length);

      gate.complete();
      await Future.wait(futures);
    });

    test('领导者取消时跟随者不受影响，全部等待者取消时中止底层请求', () async {
      final gate1 = Completer<void>();
      var firstCancelled = false;
      final gate2 = Completer<void>();
      var secondCancelled = false;
      var seq = 0;

      final adapter = _ControlledAdapter((options, cancelFuture) async {
        final current = ++seq;
        if (current == 1) {
          cancelFuture?.then((_) => firstCancelled = true);
          await gate1.future;
          return ResponseBody.fromString(
            '{"ok":1}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        cancelFuture?.then((_) {
          secondCancelled = true;
          if (!gate2.isCompleted) gate2.complete();
        });
        await gate2.future;
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'cancelled',
        );
      });

      final coalescer = RequestCoalescer(sessionGenerationProvider: () => 1);
      final dio = _createDio(adapter, coalescer: coalescer);
      addTearDown(() => dio.close(force: true));

      // 场景 A：领导者取消，跟随者继续等待并成功
      final tokenA = CancelToken();
      final tokenB = CancelToken();
      final leader = dio.get<Map<String, dynamic>>(
        '/notifications',
        cancelToken: tokenA,
        options: _coalesceOptions(),
      );
      final follower = dio.get<Map<String, dynamic>>(
        '/notifications',
        cancelToken: tokenB,
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(adapter.callCount, 1);

      tokenA.cancel('page closed');
      await expectLater(
        leader,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(firstCancelled, isFalse);

      gate1.complete();
      final followerResp = await follower;
      expect(followerResp.data?['ok'], 1);
      expect(firstCancelled, isFalse);
      expect(coalescer.activeFlightCount, 0);

      // 场景 B：所有等待者都取消，底层请求被中止且立即清理在途表
      final tokenC = CancelToken();
      final tokenD = CancelToken();
      final f3 = dio.get<Map<String, dynamic>>(
        '/notifications',
        cancelToken: tokenC,
        options: _coalesceOptions(),
      );
      final f4 = dio.get<Map<String, dynamic>>(
        '/notifications',
        cancelToken: tokenD,
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(adapter.callCount, 2);

      tokenC.cancel('c1');
      tokenD.cancel('c2');
      await expectLater(f3, throwsA(isA<DioException>()));
      await expectLater(f4, throwsA(isA<DioException>()));
      await pumpEventQueue();
      expect(secondCancelled, isTrue);
      expect(coalescer.activeFlightCount, 0);
    });

    test('前台与静默通道：静默可搭车前台，前台不降级搭车静默，noRecovery 独立隔离', () async {
      final gate = Completer<void>();
      final adapter = _ControlledAdapter((options, _) async {
        await gate.future;
        return ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      final dio = _createDio(adapter);
      addTearDown(() => dio.close(force: true));

      // 1) 前台在途时，静默请求可搭车前台（仍为 1 次底层请求）
      final fg1 = dio.get<Map<String, dynamic>>(
        '/site.json',
        options: _coalesceOptions(),
      );
      final silent1 = dio.get<Map<String, dynamic>>(
        '/site.json',
        options: _coalesceOptions(extra: {FluxRequestKeys.isSilent: true}),
      );
      // 显式 noRecovery 不搭车前台
      final noRec = dio.get<Map<String, dynamic>>(
        '/site.json',
        options: _coalesceOptions(extra: {FluxRequestKeys.noRecovery: true}),
      );
      await pumpEventQueue();
      expect(adapter.callCount, 2);

      // 2) 静默在途时，新来的前台请求不搭车静默，独立走完整前台通道
      final silent2 = dio.get<Map<String, dynamic>>(
        '/tags.json',
        options: _coalesceOptions(extra: {FluxRequestKeys.isSilent: true}),
      );
      final fg2 = dio.get<Map<String, dynamic>>(
        '/tags.json',
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(adapter.callCount, 4);

      gate.complete();
      await Future.wait([fg1, silent1, noRec, silent2, fg2]);
    });

    test('领导者内部递归重定向与 503 重试不死锁，且跟随者拿到最终成功响应', () async {
      final firstAttemptGate = Completer<void>();
      var attempt = 0;
      final adapter = _ControlledAdapter((options, _) async {
        attempt++;
        if (attempt == 1) {
          await firstAttemptGate.future;
          // 第一次返回 503，触发 RecoveryCoordinator 递归 dio.fetch 重试
          return ResponseBody.fromString('busy', 503);
        }
        if (attempt == 2) {
          // 第二次返回 302 自重定向到同路径，触发 RedirectInterceptor 递归 dio.fetch
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['/notifications'],
            },
          );
        }
        return ResponseBody.fromString(
          '{"recovered":true}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      final dio = _createDio(adapter);
      addTearDown(() => dio.close(force: true));
      dio.interceptors.add(
        RecoveryCoordinator(dio: dio, policies: const [TransientRetryPolicy()]),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) async {
            if (response.statusCode == 302) {
              final location = response.headers.value('location')!;
              final next = response.requestOptions.copyWith(
                path: location,
                extra: {...response.requestOptions.extra, '_redirectCount': 1},
              );
              handler.resolve(await dio.fetch<dynamic>(next));
              return;
            }
            handler.next(response);
          },
        ),
      );

      final f1 = dio.get<Map<String, dynamic>>(
        '/notifications',
        options: _coalesceOptions(),
      );
      final f2 = dio.get<Map<String, dynamic>>(
        '/notifications',
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(attempt, 1);

      firstAttemptGate.complete();
      final results = await Future.wait([f1, f2]);
      // 3 次底层调用全部来自领导者自身（503 重试 + 302 跟随），跟随者 0 次额外请求
      expect(attempt, 3);
      expect(results[0].data?['recovered'], isTrue);
      expect(results[1].data?['recovered'], isTrue);
    });

    test('会话代切换时隔离在途请求，且错误传播保留各自 RequestOptions', () async {
      var generation = 1;
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();
      var seq = 0;

      final adapter = _ControlledAdapter((options, _) async {
        final current = ++seq;
        if (current == 1) {
          await gate1.future;
          return ResponseBody.fromString('server error', 500);
        }
        await gate2.future;
        return ResponseBody.fromString(
          '{"gen":2}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      final coalescer = RequestCoalescer(
        sessionGenerationProvider: () => generation,
      );
      final dio = _createDio(adapter, coalescer: coalescer);
      addTearDown(() => dio.close(force: true));

      final gen1Leader = dio.get<Map<String, dynamic>>(
        '/site.json',
        options: _coalesceOptions(extra: {'tag': 'leader'}),
      );
      final gen1Follower = dio.get<Map<String, dynamic>>(
        '/site.json',
        options: _coalesceOptions(extra: {'tag': 'follower'}),
      );
      await pumpEventQueue();
      expect(adapter.callCount, 1);

      // 会话代变更后，新请求不得搭车旧会话的在途请求
      generation = 2;
      final gen2Req = dio.get<Map<String, dynamic>>(
        '/site.json',
        options: _coalesceOptions(),
      );
      await pumpEventQueue();
      expect(adapter.callCount, 2);

      gate1.complete();
      gate2.complete();

      await expectLater(gen1Leader, throwsA(isA<DioException>()));
      await expectLater(
        gen1Follower,
        throwsA(
          isA<DioException>().having(
            (e) => e.requestOptions.extra['tag'],
            'follower tag',
            'follower',
          ),
        ),
      );
      final gen2Resp = await gen2Req;
      expect(gen2Resp.data?['gen'], 2);
      expect(coalescer.activeFlightCount, 0);
    });
  });
}
