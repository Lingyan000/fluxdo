import 'dart:async';

class PluginOperationCancelled implements Exception {
  const PluginOperationCancelled();
  @override
  String toString() => 'plugin_operation_cancelled';
}

/// 每个插件独立排队。重置立即失效旧代次，再等待正在写入的数据落盘后清理。
class PluginOperationQueue {
  final _pending = <String, Future<void>>{};
  final _generations = <String, int>{};

  int generation(String id) => _generations[id] ?? 0;

  Future<T> run<T>(String id, Future<T> Function() operation) {
    final expected = generation(id);
    return _enqueue(id, () {
      if (generation(id) != expected) {
        throw const PluginOperationCancelled();
      }
      return operation();
    });
  }

  Future<T> reset<T>(String id, Future<T> Function() operation) {
    _generations[id] = generation(id) + 1;
    return _enqueue(id, operation);
  }

  Future<T> _enqueue<T>(String id, Future<T> Function() operation) {
    final result = (_pending[id] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final completion = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[id] = completion;
    unawaited(
      completion.then((_) {
        if (identical(_pending[id], completion)) _pending.remove(id);
      }),
    );
    return result;
  }
}
