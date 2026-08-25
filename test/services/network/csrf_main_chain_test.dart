import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/csrf_token_service.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/network/interceptors/request_header_interceptor.dart';

/// CSRF 刷新走主链后的关键契约。
///
/// 背景:CsrfTokenService 原先自建一个只装 3 个拦截器的独立 Dio,在后台/
/// 会话失效窗口撞 CF 会静默失败(UserApiKeyService 的注释记录了这次事故)。
/// 现改为由 DiscourseService 注入主 dio。同处一条链后,以下两点成为硬约束:
///
/// 1. **不能递归**:RequestHeaderInterceptor 在 POST 前触发刷新,而刷新请求
///    自己也要过这个拦截器 —— 靠 skipCsrf 断开。
/// 2. **不能自锁**:刷新请求必须绕过并发调度器。否则 POST 占着槽位等 CSRF、
///    CSRF 在队列里等槽位,直接死锁。
///
/// 注意:CsrfTokenService 是单例且 attachDio 幂等(只认第一次),所以整个
/// 文件共用一个 dio/adapter,不能每个测试各建一套。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = CsrfTokenService();
  final adapter = _CsrfAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(RequestHeaderInterceptor(service));
  service.attachDio(dio);

  setUp(() {
    adapter.reset();
    // 单例带失败冷却,跨测试会互相干扰
    service.clearCsrfToken();
  });

  test('刷新走注入的主链，且不递归触发二次刷新', () async {
    await service.updateCsrfToken();

    // 只发了一次 /session/csrf —— skipCsrf 断开了递归
    expect(adapter.csrfCallCount, 1);
    expect(service.csrfToken, 'token-from-main-chain');
  });

  test('刷新请求的 extra 同时具备 skipCsrf / skipScheduler / isSilent', () async {
    await service.updateCsrfToken();

    final spec = FluxRequestSpec(adapter.lastExtra!);
    // 断开递归
    expect(spec.skipCsrf, isTrue, reason: '否则过 RequestHeaderInterceptor 会再刷一次');
    // 防自锁:POST 等 CSRF、CSRF 等槽位
    expect(spec.skipScheduler, isTrue, reason: '刷新必须绕过并发调度器');
    // 静默 → 天然旁路恢复层,不会被重放
    expect(spec.isSilent, isTrue);
    expect(spec.recoveryDisabled, isTrue, reason: '刷新失败由自己的冷却处理,不重放');
    // 链路标签便于日志归因
    expect(spec.requestTag, 'csrf-refresh');
  });

  test('并发刷新合流为一次请求(单飞)', () async {
    await Future.wait([
      service.updateCsrfToken(),
      service.updateCsrfToken(),
      service.updateCsrfToken(),
    ]);

    expect(adapter.csrfCallCount, 1, reason: '三个并发调用应共享同一次刷新');
  });

  test('attachDio 幂等:重复注册不会替换已有的主 dio', () async {
    final intruder = _CsrfAdapter();
    service.attachDio(
      Dio(BaseOptions(baseUrl: 'https://other.example'))
        ..httpClientAdapter = intruder,
    );

    await service.updateCsrfToken();

    // 幂等保证短命的业务 dio(OAuth/下载等)顶不掉主 dio
    expect(intruder.csrfCallCount, 0, reason: '第二次注册应被忽略');
    expect(adapter.csrfCallCount, 1, reason: '仍走首次注册的主 dio');
  });
}

class _CsrfAdapter implements HttpClientAdapter {
  int csrfCallCount = 0;
  Map<String, dynamic>? lastExtra;

  void reset() {
    csrfCallCount = 0;
    lastExtra = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/session/csrf') {
      csrfCallCount++;
      lastExtra = Map<String, dynamic>.from(options.extra);
    }
    return ResponseBody.fromString(
      '{"csrf":"token-from-main-chain"}',
      200,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
