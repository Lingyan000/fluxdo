import 'dart:async';
import 'dart:collection';

/// 文件激活先入队，界面就绪后串行确认。重复激活不会叠加安装弹框。
class MetaversePluginFileQueue {
  MetaversePluginFileQueue({required this.onError, this.onConsumed});

  final void Function(Object, StackTrace) onError;
  final void Function(Uri)? onConsumed;
  final _pending = Queue<Uri>();
  final _identities = <Uri>{};
  Future<bool> Function(Uri)? _handler;
  bool _running = false;

  int get pendingCount => _pending.length;

  void add(Uri uri) {
    final normalized = uri.normalizePath();
    if (!_identities.add(normalized)) return;
    _pending.add(normalized);
    unawaited(_drain());
  }

  /// 返回 false 表示导航已卸载，保留当前文件供下一界面处理。
  void attach(Future<bool> Function(Uri) handler) {
    _handler = handler;
    unawaited(_drain());
  }

  void detach() => _handler = null;

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty && _handler != null) {
        final handler = _handler!;
        final uri = _pending.first;
        var completed = true;
        try {
          completed = await handler(uri);
        } catch (error, stack) {
          onError(error, stack);
        }
        if (!completed) {
          if (identical(handler, _handler)) _handler = null;
          continue;
        }
        _pending.removeFirst();
        _identities.remove(uri);
        onConsumed?.call(uri);
      }
    } finally {
      _running = false;
    }
  }
}
