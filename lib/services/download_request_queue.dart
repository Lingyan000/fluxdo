import 'dart:async';

/// 下载请求优先级(Telegram FileLoaderPriorityQueue 的两级简化)。
enum DownloadPriority {
  /// 在视口内 / 用户主动操作(查看器、保存、分享)。
  high,

  /// 预建 / 预取 / 已滚出视口。
  normal,
}

/// 两级优先级信号量：可准入的 high 先行，同级组间轮转、组内 FIFO。
/// 未配置分组时沿用原有同级 FIFO。
///
/// 配合下载客户端的 bumpPending / sinkPending：
/// 排队中的请求可随视野变化在两级间迁移(滚入视野 → high 插队,
/// 视图释放 → 沉回 normal 队尾)。这里只管理排队准入，不取消在途 HTTP。
class DownloadRequestQueue {
  DownloadRequestQueue(
    this.maxCount, {
    this.reservedHighSlots = 0,
    Map<String, int> groupLimits = const {},
  }) : groupLimits = Map.unmodifiable(groupLimits),
       _groupOrder = [...groupLimits.keys, null],
       assert(maxCount > 0),
       assert(reservedHighSlots >= 0 && reservedHighSlots < maxCount),
       assert(
         groupLimits.values.every((limit) => limit > 0 && limit <= maxCount),
       );

  /// 可选的组内上限。同级请求在组间轮转，组内仍为 FIFO。
  /// 空闲预算可由其他组使用，但总数不超过 maxCount。
  final Map<String, int> groupLimits;
  final List<String?> _groupOrder;
  final _activeGroups = <String?, int>{};
  String? _lastGroup;

  final int reservedHighSlots;

  final int maxCount;
  int _current = 0;
  final _high = <_Waiter>[];
  final _normal = <_Waiter>[];
  final _foregroundUsers = <String, int>{};

  /// 当前是否有视图持有前台优先权，供下载准入时记录诊断快照。
  bool isForeground(String key) => _foregroundUsers.containsKey(key);

  /// 保留提权意图直到视图释放，即使首绘发生在 acquire 之前也不会丢失。
  /// 多个视图共享 URL 时，最后一个释放者才降低隐式前台优先级。
  void Function() retainForeground(String key) {
    _foregroundUsers.update(key, (n) => n + 1, ifAbsent: () => 1);
    bump(key);
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = _foregroundUsers[key]! - 1;
      if (count > 0) {
        _foregroundUsers[key] = count;
        return;
      }
      _foregroundUsers.remove(key);
      final demoted = <_Waiter>[];
      _high.removeWhere((w) {
        final match = w.key == key && w.priority == DownloadPriority.normal;
        if (match) demoted.add(w);
        return match;
      });
      _normal.addAll(demoted);
      _drain();
    };
  }

  Future<void> acquire(
    String key,
    DownloadPriority priority, {
    Future<void>? cancelled,
    String? group,
  }) {
    if (group != null && !groupLimits.containsKey(group)) {
      throw ArgumentError.value(group, 'group', '未配置下载组');
    }
    final w = _Waiter(key, priority, group);
    final foreground =
        priority == DownloadPriority.high || _foregroundUsers.containsKey(key);
    (foreground ? _high : _normal).add(w);
    _drain();
    if (cancelled != null) {
      unawaited(
        Future.any([
          cancelled.then((_) {
            if (_high.remove(w) || _normal.remove(w)) {
              w.completer.completeError(const DownloadQueueCancelled());
            }
          }),
          w.completer.future.then((_) {}, onError: (_) {}),
        ]),
      );
    }
    return w.completer.future;
  }

  int _eligibleIndex(List<_Waiter> queue) {
    if (groupLimits.isEmpty) return queue.isEmpty ? -1 : 0;
    final firstByGroup = <String?, int>{};
    for (var i = 0; i < queue.length; i++) {
      final group = queue[i].group;
      if (firstByGroup.containsKey(group)) continue;
      final limit = groupLimits[group] ?? maxCount;
      if ((_activeGroups[group] ?? 0) < limit) firstByGroup[group] = i;
    }
    // 真正的轮转，而非仅避开上一个组；后三组混排时也不会饿死第三组。
    final last = _groupOrder.indexOf(_lastGroup);
    for (var step = 1; step <= _groupOrder.length; step++) {
      final group = _groupOrder[(last + step) % _groupOrder.length];
      final index = firstByGroup[group];
      if (index != null) return index;
    }
    return -1;
  }

  void _drain() {
    while (_current < maxCount) {
      var queue = _high;
      var index = _eligibleIndex(queue);
      if (index == -1) {
        // 后台不能占最后的前台保留槽；不增加总并发。
        if (_current >= maxCount - reservedHighSlots) break;
        queue = _normal;
        index = _eligibleIndex(queue);
      }
      if (index == -1) break;
      final waiter = queue.removeAt(index);
      _current++;
      _activeGroups.update(waiter.group, (n) => n + 1, ifAbsent: () => 1);
      _lastGroup = waiter.group;
      waiter.completer.complete();
    }
  }

  void release({String? group}) {
    final count = _activeGroups[group] ?? 0;
    if (count == 0) throw StateError('下载槽重复释放或下载组不匹配');
    if (count == 1) {
      _activeGroups.remove(group);
    } else {
      _activeGroups[group] = count - 1;
    }
    _current--;
    _drain();
  }

  /// 把排队中的 [key] 提到 high 队尾(已在 high / 未在队列则无操作)。
  void bump(String key) {
    _normal.removeWhere((w) {
      if (w.key != key) return false;
      _high.add(w);
      return true;
    });
    _drain();
  }

  /// 把排队中的 [key] 沉到 normal 队尾(滚出视野的预建请求让路)。
  void sink(String key) {
    if (_foregroundUsers.containsKey(key)) return;
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
  _Waiter(this.key, this.priority, this.group);
  final String? group;
  final String key;
  final DownloadPriority priority;
  final completer = Completer<void>();
}

class DownloadQueueCancelled implements Exception {
  const DownloadQueueCancelled();
}
