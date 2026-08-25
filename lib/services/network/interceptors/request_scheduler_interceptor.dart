import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../browser_trust_coordinator.dart';
import '../../cf_challenge_service.dart';
import '../exceptions/api_exception.dart';
import '../cookie/cookie_jar_service.dart';
import '../flux_request_spec.dart';
import '../request_scheduler_config.dart';

/// 请求优先级
enum _Priority {
  high(0), // 用户写操作（POST/PUT/DELETE/PATCH）
  normal(1), // 普通 GET 请求
  low(2); // 静默请求（心跳、后台刷新）

  const _Priority(this.value);
  final int value;
}

/// 排队条目
class _RequestEntry {
  final RequestOptions options;
  final RequestInterceptorHandler handler;
  final _Priority priority;
  final int sequence; // 同优先级 FIFO
  final Completer<void> completer = Completer<void>();
  bool isCancelled = false;

  _RequestEntry({
    required this.options,
    required this.handler,
    required this.priority,
    required this.sequence,
  });
}

/// 基于 HeapPriorityQueue 的优先级队列
class _PriorityQueue {
  final _queue = HeapPriorityQueue<_RequestEntry>((a, b) {
    final cmp = a.priority.value.compareTo(b.priority.value);
    if (cmp != 0) return cmp;
    return a.sequence.compareTo(b.sequence);
  });

  bool get isEmpty => _queue.isEmpty;
  bool get isNotEmpty => _queue.isNotEmpty;
  int get length => _queue.length;

  void add(_RequestEntry entry) => _queue.add(entry);

  _RequestEntry removeFirst() => _queue.removeFirst();
}

/// 滑动窗口速率限制器
///
/// 动态读取 [RequestSchedulerConfig] 的配置值，
/// 用户修改设置后立即生效。
class _RateLimiter {
  final _timestamps = Queue<DateTime>();

  /// 驱逐过期时间戳
  void _evict(DateTime now) {
    final cutoff = now.subtract(
      Duration(seconds: RequestSchedulerConfig.windowSeconds),
    );
    while (_timestamps.isNotEmpty && _timestamps.first.isBefore(cutoff)) {
      _timestamps.removeFirst();
    }
  }

  /// 是否可以发出请求
  bool canProceed() {
    _evict(DateTime.now());
    return _timestamps.length < RequestSchedulerConfig.maxPerWindow;
  }

  /// 需要等待的时间（队列未满时返回 Duration.zero）
  Duration get waitDuration {
    final now = DateTime.now();
    _evict(now);
    if (_timestamps.length < RequestSchedulerConfig.maxPerWindow) {
      return Duration.zero;
    }
    // 最早的时间戳 + 窗口大小 - 当前时间
    return _timestamps.first
        .add(Duration(seconds: RequestSchedulerConfig.windowSeconds))
        .difference(now);
  }

  /// 记录一个请求发出
  void record() {
    _timestamps.add(DateTime.now());
  }
}

/// 单个 host 维度的调度状态
///
/// 同一 host 的所有 dio 实例共享同一份 [_HostState], 避免出现:
/// - 主站 dio + LdcOAuthService 内部 dio + CdkOAuthService 内部 dio 各自一份
///   窗口, 用户视角的真实速率 = 各 host 之和, 远超用户在设置里配的阈值,
///   导致服务端按 IP/cookie 维度统计后直接 429。
class _HostState {
  int running = 0;
  int sequence = 0;
  Timer? pendingTimer;
  final _PriorityQueue queue = _PriorityQueue();
  final _RateLimiter rateLimiter = _RateLimiter();
}

/// 请求调度拦截器
///
/// 替代 ConcurrencyInterceptor，增加：
/// - 优先级调度：用户操作 > 普通 GET > 后台静默请求
/// - 取消过时请求：排队中的请求被 cancelToken 取消时自动跳过
/// - 滑动窗口速率限制：防止密集请求触发服务端 429
/// - 按 host 共享: 所有 dio 实例同 host 共用同一窗口, 与服务端按 IP/cookie
///   计速率的视角对齐
///
/// 并发数和速率限制从 [RequestSchedulerConfig] 动态读取。
class RequestSchedulerInterceptor extends Interceptor {
  /// 按 host 共享的状态表。key = uri.host 小写。
  static final Map<String, _HostState> _states = {};

  static _HostState _stateFor(RequestOptions options) {
    final host = options.uri.host.toLowerCase();
    return _states.putIfAbsent(host, _HostState.new);
  }

  /// 推断请求优先级
  _Priority _inferPriority(RequestOptions options) {
    // 显式指定优先级
    final explicit = options.spec.explicitPriority;
    if (explicit != null) {
      switch (explicit) {
        case FluxRequestPriority.high:
          return _Priority.high;
        case FluxRequestPriority.low:
          return _Priority.low;
        default:
          return _Priority.normal;
      }
    }

    // isSilent 标记 → low
    if (options.spec.isSilent) {
      return _Priority.low;
    }

    // 写操作 → high
    final method = options.method.toUpperCase();
    if (method == 'POST' ||
        method == 'PUT' ||
        method == 'DELETE' ||
        method == 'PATCH') {
      return _Priority.high;
    }

    // 其他 GET → normal
    return _Priority.normal;
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 内部请求（如 CSRF 刷新）跳过调度，避免与调用方死锁
    if (options.spec.skipScheduler) {
      handler.next(options);
      return;
    }

    // CF 验证进行中时冻结所有业务请求，模拟"网页 CF 403 直接停滞"的语义，
    // 避免挑战完成瞬间一次性 flush 心跳/poll/timings 触发服务端 429，
    // 同时也能防止用户在验证弹窗期间触发的请求带着旧 cf_clearance 又判 403
    // 进入挑战循环。
    //
    // 仅 CfChallengeInterceptor 内部 retry（标记 skipCfBlock=true）能绕过。
    if (!options.spec.skipCfBlock &&
        CfChallengeService().isVerifying) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: CfChallengeException(silentBlockedDuringChallenge: true),
        ),
        true,
      );
      return;
    }

    await _waitForBrowserTrustIfNeeded(options);

    final state = _stateFor(options);
    final priority = _inferPriority(options);
    final maxConcurrent = RequestSchedulerConfig.maxConcurrent;

    // cancelToken 已取消，直接拒绝
    if (options.cancelToken?.isCancelled ?? false) {
      handler.reject(
        DioException.requestCancelled(
          requestOptions: options,
          reason: '请求在排队前已被取消',
        ),
        true,
      );
      return;
    }

    // 有空闲槽位且速率限制允许 → 直接放行
    if (state.running < maxConcurrent && state.rateLimiter.canProceed()) {
      state.running++;
      state.rateLimiter.record();
      options.extra['_schedulerCounted'] = true;
      handler.next(options);
      return;
    }

    // 排队等待
    final entry = _RequestEntry(
      options: options,
      handler: handler,
      priority: priority,
      sequence: state.sequence++,
    );
    state.queue.add(entry);

    // 注册 cancelToken 取消回调
    options.cancelToken?.whenCancel.then((_) {
      if (!entry.completer.isCompleted) {
        entry.isCancelled = true;
        entry.completer.complete();
      }
    });

    debugPrint(
      '[Scheduler] 排队: ${options.method} ${options.path} '
      'host=${options.uri.host} 优先级=${priority.name} '
      '队列长度=${state.queue.length} 并发=${state.running}',
    );

    await entry.completer.future;

    // 被唤醒后检查是否已取消
    if (entry.isCancelled) {
      handler.reject(
        DioException.requestCancelled(
          requestOptions: options,
          reason: '请求在排队中被取消',
        ),
        true,
      );
      return;
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.requestOptions.extra.remove('_schedulerCounted') == true) {
      _release(response.requestOptions);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.extra.remove('_schedulerCounted') == true) {
      _release(err.requestOptions);
    }
    handler.next(err);
  }

  void _release(RequestOptions options) {
    final state = _stateFor(options);
    state.running--;
    _scheduleNext(state);
  }

  void _scheduleNext(_HostState state) {
    final maxConcurrent = RequestSchedulerConfig.maxConcurrent;
    while (state.queue.isNotEmpty && state.running < maxConcurrent) {
      final entry = state.queue.removeFirst();

      // 跳过已取消的 entry
      if (entry.isCancelled || entry.completer.isCompleted) {
        continue;
      }

      // 检查速率限制
      if (!state.rateLimiter.canProceed()) {
        // 放回队列等速率窗口，设置 Timer 延迟重调度
        state.queue.add(entry);
        _scheduleDelayed(state);
        return;
      }

      state.running++;
      state.rateLimiter.record();
      entry.options.extra['_schedulerCounted'] = true;
      entry.completer.complete();
    }
  }

  /// 用 Timer 延迟重调度，避免多个 Timer 同时存在
  void _scheduleDelayed(_HostState state) {
    if (state.pendingTimer?.isActive ?? false) return;
    final wait = state.rateLimiter.waitDuration;
    if (wait <= Duration.zero) {
      _scheduleNext(state);
      return;
    }
    state.pendingTimer = Timer(wait, () {
      state.pendingTimer = null;
      _scheduleNext(state);
    });
  }

  Future<void> _waitForBrowserTrustIfNeeded(RequestOptions options) async {
    // CF 验证自身的重试请求不等信任门(避免与验证流程互锁)。
    // challenge-platform 请求现全部在 WebView 内发起,不经过 dio,
    // 故此处不再需要判定它。
    if (options.spec.skipCfBlock) {
      return;
    }

    final host = options.uri.host;
    if (host.isEmpty || !CookieJarService.matchesAppHost(host)) {
      return;
    }

    await BrowserTrustCoordinator.instance.waitForActiveBrowserTrust(
      reason: '${options.method.toUpperCase()} ${options.uri}',
    );
  }
}
