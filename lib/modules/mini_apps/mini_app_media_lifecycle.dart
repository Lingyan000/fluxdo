import 'dart:async';

typedef MiniAppMediaOperation = Future<void> Function(
  bool suspended,
  bool Function() isCurrent,
);

/// 跟随原生实例，而非临时挂载它的页面。收起/恢复及弹窗切页面共用顺序。
/// 两条通道分别收敛到最新状态，慢网页脚本不能阻塞原生 WebView 的恢复。
class MiniAppMediaLifecycle {
  final _platform = _LatestMediaOperation();
  final _host = _LatestMediaOperation();
  MiniAppMediaBinding? _binding;
  bool _disposed = false;

  MiniAppMediaBinding bind({
    required MiniAppMediaOperation platform,
    required MiniAppMediaOperation host,
  }) {
    return _binding = MiniAppMediaBinding._(this, platform, host);
  }

  void dispose() {
    _disposed = true;
    _binding = null;
    _platform.dispose();
    _host.dispose();
  }
}

class MiniAppMediaBinding {
  MiniAppMediaBinding._(this._owner, this._platform, this._host);
  final MiniAppMediaLifecycle _owner;
  final MiniAppMediaOperation _platform, _host;

  /// 同步记录目标，调用者不等待插件回执；菜单/手势退场不受慢操作影响。
  void update({required bool suspended, bool refreshHost = false}) {
    if (_owner._disposed || _owner._binding != this) return;
    _owner._platform.request(suspended, _platform);
    _owner._host.request(suspended, _host, force: refreshHost);
  }
}

class _LatestMediaOperation {
  MiniAppMediaOperation? _operation;
  bool? _suspended;
  int _revision = 0;
  bool _running = false, _disposed = false;

  void request(
    bool suspended,
    MiniAppMediaOperation operation, {
    bool force = false,
  }) {
    if (_disposed ||
        (!force && suspended == _suspended && operation == _operation)) {
      return;
    }
    _suspended = suspended;
    _operation = operation;
    _revision++;
    if (!_running) unawaited(_drain());
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (!_disposed) {
        final revision = _revision;
        try {
          // 不以 timeout 假装操作已取消：迟到的 pause 仍可能改变原生状态。
          // 保持真实执行顺序，完成后立刻应用其间收到的最新目标。
          await _operation!(
            _suspended!,
            () => !_disposed && revision == _revision,
          );
        } catch (_) {
          // 不支持的方法或已销毁视图不阻断后续状态。
        }
        if (revision == _revision) return;
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _revision++;
    _operation = null;
  }
}
