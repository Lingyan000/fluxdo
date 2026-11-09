import 'package:flutter/foundation.dart';

import '../../log/log_writer.dart';

/// 只观察真实核心请求，不发起探测，也不参与重试、降级或路由选择。
/// 以 origin 聚合连续故障；成功响应、配置重建和连接重置结束当前记录。
class NetworkHealthMonitor extends ChangeNotifier {
  NetworkHealthMonitor({
    DateTime Function()? now,
    void Function(Map<String, dynamic>)? write,
  }) : _now = now ?? DateTime.now,
       _write = write ?? LogWriter.instance.write;

  static final instance = NetworkHealthMonitor();
  static const maxOrigins = 32;
  final DateTime Function() _now;
  final void Function(Map<String, dynamic>) _write;
  final Map<String, _OriginHealth> _origins = {};
  int _generation = 0;
  int _sequence = 0;

  CoreRequestObservation begin(Uri uri, {String? traceId, int? requestId}) =>
      CoreRequestObservation._(
        uri.origin,
        _generation,
        ++_sequence,
        traceId,
        requestId,
      );

  NetworkHealthSnapshot? get problem {
    for (final state in _origins.values.toList().reversed) {
      if (state.failures > 0) return state.snapshot;
    }
    return null;
  }

  NetworkHealthSnapshot? forOrigin(Uri uri) => _origins[uri.origin]?.snapshot;

  void headers(
    CoreRequestObservation observation, {
    required int statusCode,
    String? protocol,
    int? connectMs,
    int? ttfbMs,
  }) {
    observation
      ..statusCode = statusCode
      ..protocol = protocol
      ..connectMs = connectMs
      ..ttfbMs = ttfbMs;
    final state = _state(observation);
    if (state == null || state.failures > 0 || state.responded) return;
    state.responded = true;
    notifyListeners();
  }

  /// 读完响应体才结束故障记录，避免慢响应体在每次拿到头时被误报恢复。
  void completed(CoreRequestObservation observation) {
    final state = _state(observation);
    if (state == null ||
        observation.sequence < state.lastFailureSequence ||
        observation.sequence < state.lastSuccessSequence) {
      return;
    }
    final changed = !state.responded || state.failures > 0;
    if (state.failures > 0) {
      _emit('transport_recovered', state, observation);
    }
    state
      ..lastSuccessSequence = observation.sequence
      ..responded = true
      ..failures = 0
      ..firstFailure = null;
    if (changed) notifyListeners();
  }

  void failed(CoreRequestObservation observation, {required String kind}) {
    if (kind == 'cancelled') return;
    final state = _state(observation);
    if (state == null || observation.sequence < state.lastSuccessSequence) {
      return;
    }
    state.lastFailureSequence = observation.sequence > state.lastFailureSequence
        ? observation.sequence
        : state.lastFailureSequence;
    state.failures++;
    state.firstFailure ??= _now();
    state.lastKind = kind;
    state.phase = observation.statusCode == null
        ? 'before_response'
        : 'response_body';
    if (state.failures == 1) {
      _emit('transport_failure_started', state, observation);
    }
    notifyListeners();
  }

  /// 旧网络的迟到响应不得改写当前结果；重置本身不等于网络恢复。
  void reset({required String reason}) {
    for (final state in _origins.values.where((s) => s.failures > 0)) {
      _emit('transport_observation_reset', state, null, reason: reason);
    }
    _generation++;
    final changed = _origins.isNotEmpty;
    _origins.clear();
    if (changed) notifyListeners();
  }

  _OriginHealth? _state(CoreRequestObservation observation) {
    if (observation.generation != _generation) return null;
    final existing = _origins.remove(observation.origin);
    if (existing == null && _origins.length >= maxOrigins) {
      final evicted = _origins.remove(_origins.keys.first)!;
      if (evicted.failures > 0) {
        _emit('transport_observation_reset', evicted, null, reason: 'capacity');
      }
    }
    final state = existing ?? _OriginHealth(observation.origin);
    _origins[observation.origin] = state;
    return state;
  }

  void _emit(
    String event,
    _OriginHealth state,
    CoreRequestObservation? observation, {
    String? reason,
  }) {
    final now = _now();
    _write({
      'timestamp': now.toIso8601String(),
      'level': event == 'transport_failure_started' ? 'warning' : 'info',
      'type': 'network',
      'event': event,
      'message': '$event ${state.origin}',
      'origin': state.origin,
      'failureCount': state.failures,
      'lastErrorKind': state.lastKind,
      'failurePhase': state.phase,
      'episodeMs': state.firstFailure == null
          ? 0
          : now
                .difference(state.firstFailure!)
                .inMilliseconds
                .clamp(0, 1 << 53),
      'reason': ?reason,
      if (observation != null) ...{
        'traceId': observation.traceId,
        'coreRequestId': observation.requestId,
        'requestMs': observation.elapsed.elapsedMilliseconds,
        'statusCode': observation.statusCode,
        'httpVersion': observation.protocol,
        'connectMs': observation.connectMs,
        'ttfbMs': observation.ttfbMs,
      },
    });
  }
}

class CoreRequestObservation {
  CoreRequestObservation._(
    this.origin,
    this.generation,
    this.sequence,
    this.traceId,
    this.requestId,
  );
  final String origin;
  final int generation, sequence;
  final String? traceId;
  final int? requestId;
  final Stopwatch elapsed = Stopwatch()..start();
  int? statusCode, connectMs, ttfbMs;
  String? protocol;
}

@immutable
class NetworkHealthSnapshot {
  const NetworkHealthSnapshot({
    required this.origin,
    required this.responded,
    required this.failures,
  });
  final String origin;
  final bool responded;
  final int failures;
  String get host => Uri.parse(origin).host;
}

class _OriginHealth {
  _OriginHealth(this.origin);
  final String origin;
  bool responded = false;
  int lastSuccessSequence = 0, lastFailureSequence = 0, failures = 0;
  DateTime? firstFailure;
  String? lastKind, phase;
  NetworkHealthSnapshot get snapshot => NetworkHealthSnapshot(
    origin: origin,
    responded: responded,
    failures: failures,
  );
}
