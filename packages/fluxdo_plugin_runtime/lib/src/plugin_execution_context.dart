import 'dart:async';

/// 由宿主创建，异步调用和公共服务沿用同一份归属信息。
class PluginExecutionContext {
  const PluginExecutionContext({
    required this.pluginId,
    required this.pluginVersion,
    required this.runtimeId,
    this.surfaceId,
    this.traceId,
    this.emitter = 'framework',
  });

  static final Object _zoneKey = Object();
  static PluginExecutionContext? get current =>
      Zone.current[_zoneKey] as PluginExecutionContext?;

  final String pluginId;
  final String pluginVersion;
  final String runtimeId;
  final String? surfaceId;
  final String? traceId;
  final String emitter;

  Map<String, Object> get fields => {
    'pluginId': pluginId,
    'pluginVersion': pluginVersion,
    'runtimeId': runtimeId,
    'surfaceId': ?surfaceId,
    'traceId': ?traceId,
    'emitter': emitter,
  };

  T run<T>(T Function() operation) =>
      runZoned(operation, zoneValues: {_zoneKey: this});
}
