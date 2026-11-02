import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../utils/time_utils.dart';
import 'app_logger.dart';
import 'message_bus_service.dart';

/// MessageBus 投递时效探针（诊断用）
///
/// /latest 消息的 payload 带 bumped_at（话题被顶起的服务端时刻，发帖后
/// 立即发布），用它估算「服务端发布 → 客户端收到」的传输延迟，同时记录
/// 滚动期延迟投递额外压了多久。按时间窗聚合后落一条日志（日志页
/// tag=MessageBus），用来判断分块流式在真机链路上是否被代理缓冲：
/// 分块模式下中位数应在 1~2 秒内，十几秒以上说明响应被攒着发。
///
/// 读数注意：
/// - 设备时钟与服务端可能有偏差，看中位数趋势，不看单条（可能为负）；
/// - 断线/后台恢复后的积压回放、非发帖触发的 latest（如改分类）天然
///   延迟大，超过 [staleThreshold] 的单独计为 stale，不混进分位数。
class MessageBusLatencyProbe {
  MessageBusLatencyProbe({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _windowStart = _clock();
  }

  static const String channel = '/latest';
  static const Duration reportInterval = Duration(minutes: 5);
  static const Duration staleThreshold = Duration(seconds: 60);
  static const int _maxSamples = 1000;

  final DateTime Function() _clock;
  final List<int> _transportMs = [];
  int _chunked = 0;
  int _plain = 0;
  int _stale = 0;
  int _maxDeliveryDelayMs = 0;
  late DateTime _windowStart;

  /// 协议层收到消息时调用（早于滚动期延迟投递）
  void onReceived(MessageBusMessage message, {required bool chunked}) {
    if (message.channel != channel) return;
    final data = message.data;
    if (data is! Map<String, dynamic>) return;
    final payload = data['payload'];
    if (payload is! Map<String, dynamic>) return;
    final bumpedAt = TimeUtils.parseUtcTime(payload['bumped_at'] as String?);
    if (bumpedAt == null) return;

    chunked ? _chunked++ : _plain++;
    final transport = message.receivedAt.difference(bumpedAt);
    if (transport > staleThreshold) {
      _stale++;
    } else if (_transportMs.length < _maxSamples) {
      _transportMs.add(transport.inMilliseconds);
    }
    _maybeReport();
  }

  /// 消息真正投递给订阅方时调用，记录滚动期延迟投递压了多久
  void onDelivered(MessageBusMessage message) {
    if (message.channel != channel) return;
    final delay = _clock().difference(message.receivedAt).inMilliseconds;
    if (delay > _maxDeliveryDelayMs) _maxDeliveryDelayMs = delay;
  }

  void _maybeReport() {
    final now = _clock();
    final window = now.difference(_windowStart);
    if (window < reportInterval) return;

    final summary = summarize();
    AppLogger.info(
      '/latest 投递延迟 p50=${summary['p50Ms']}ms p90=${summary['p90Ms']}ms '
      '(样本 ${summary['samples']}, 积压 $_stale, 分块 $_chunked/普通 $_plain)',
      tag: 'MessageBus',
      fields: {...summary, 'windowSec': window.inSeconds},
    );
    _reset(now);
  }

  @visibleForTesting
  Map<String, dynamic> summarize() {
    final sorted = [..._transportMs]..sort();
    int? percentile(double p) => sorted.isEmpty
        ? null
        : sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];
    return {
      'samples': sorted.length,
      'p50Ms': percentile(0.5),
      'p90Ms': percentile(0.9),
      'maxMs': sorted.isEmpty ? null : sorted.last,
      'stale': _stale,
      'chunked': _chunked,
      'plain': _plain,
      'maxDeliveryDelayMs': _maxDeliveryDelayMs,
    };
  }

  void _reset(DateTime now) {
    _transportMs.clear();
    _chunked = 0;
    _plain = 0;
    _stale = 0;
    _maxDeliveryDelayMs = 0;
    _windowStart = now;
  }
}
