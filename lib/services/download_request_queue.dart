import 'dart:async';

/// 下载请求优先级(Telegram FileLoaderPriorityQueue 的两级简化)。
enum DownloadPriority {
  /// 在视口内 / 用户主动操作(查看器、保存、分享)。
  high,

  /// 预建 / 预取 / 已滚出视口。
  normal,
}

/// 两级优先级信号量:释放槽位时 high 队列先行;同级 FIFO。
///
/// 配合下载客户端的 bumpPending / sinkPending：
/// 排队中的请求可随视野变化在两级间迁移(滚入视野 → high 插队,
/// 滚出视野 → 沉回 normal 队尾),在途请求不动 —— 已下载字节写盘
/// 即缓存,取消只会白扔投资(我们没有 TG 的 .temp 断点续传,几 MB
/// 以下文件也不值得建)。
class DownloadRequestQueue {
  DownloadRequestQueue(this.maxCount, {this.reservedHighSlots = 0})
    : assert(maxCount > 0),
      assert(reservedHighSlots >= 0 && reservedHighSlots < maxCount);

  final int reservedHighSlots;

  final int maxCount;
  int _current = 0;
  final _high = <_Waiter>[];
  final _normal = <_Waiter>[];

  Future<void> acquire(String key, DownloadPriority priority) {
    final w = _Waiter(key);
    (priority == DownloadPriority.high ? _high : _normal).add(w);
    _drain();
    return w.completer.future;
  }

  void _drain() {
    while (_current < maxCount) {
      final queue = _high.isNotEmpty ? _high : _normal;
      if (queue.isEmpty) break;
      // 后台不能占最后的前台保留槽；不增加总并发。
      if (_high.isEmpty && _current >= maxCount - reservedHighSlots) break;
      _current++;
      queue.removeAt(0).completer.complete();
    }
  }

  void release() {
    if (_current == 0) throw StateError('下载槽重复释放');
    _current--;
    _drain();
  }

  /// 把排队中的 [key] 提到 high 队尾(已在 high / 未在队列则无操作)。
  void bump(String key) {
    final i = _normal.indexWhere((w) => w.key == key);
    if (i < 0) return;
    _high.add(_normal.removeAt(i));
    _drain();
  }

  /// 把排队中的 [key] 沉到 normal 队尾(滚出视野的预建请求让路)。
  void sink(String key) {
    final i = _high.indexWhere((w) => w.key == key);
    if (i >= 0) {
      _normal.add(_high.removeAt(i));
      return;
    }
    // 已在 normal:移到队尾(后来的视野内请求先走)
    final j = _normal.indexWhere((w) => w.key == key);
    if (j >= 0 && j != _normal.length - 1) {
      _normal.add(_normal.removeAt(j));
    }
  }
}

class _Waiter {
  _Waiter(this.key);
  final String key;
  final completer = Completer<void>();
}
