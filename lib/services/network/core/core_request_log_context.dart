/// 原生回调通过请求号找回调用归属，完成后到达的日志使用有界缓存。
class CoreRequestLogContext {
  CoreRequestLogContext({this.completedLimit = 512})
    : assert(completedLimit > 0);

  static final instance = CoreRequestLogContext();
  final int completedLimit;
  final _active = <int, Map<String, Object>>{};
  final _completed = <int, Map<String, Object>>{};

  void register(int requestId, Map<String, Object> fields) {
    if (requestId <= 0) return;
    _completed.remove(requestId);
    _active[requestId] = Map.unmodifiable(fields);
  }

  Map<String, Object> fieldsFor(Object? requestId) =>
      _active[requestId] ?? _completed[requestId] ?? const {};

  void complete(int requestId) {
    final fields = _active.remove(requestId);
    if (fields == null) return;
    _completed[requestId] = fields;
    while (_completed.length > completedLimit) {
      _completed.remove(_completed.keys.first);
    }
  }
}
