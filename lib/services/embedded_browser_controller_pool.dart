import 'package:flutter/foundation.dart';

enum EmbeddedBrowserPriority { video, iframe }

/// 帖子内嵌入式浏览器 Controller 的全局槽位。
class EmbeddedBrowserLease {
  EmbeddedBrowserLease._(
    this._owner, {
    required this.id,
    required this.priority,
    required this.onRevoked,
  });

  final EmbeddedBrowserControllerPool _owner;
  final int id;
  final EmbeddedBrowserPriority priority;
  final VoidCallback onRevoked;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(this);
  }

  void _revoke() {
    if (_released) return;
    _released = true;
    Future<void>.microtask(onRevoked);
  }
}

/// Windows WebView2 嵌入视图限流。
///
/// 长话题中每个视频/iframe 都拥有独立 CompositionController；
/// 不设上限会让 Controller 创建/销毁风暴与主 Win32 消息泵互相影响。
/// 这里将帖子内 Controller 总数限制为 3。
///
/// 不能通过“先异步销毁旧 Controller、同时立即创建新 Controller”抢占：
/// WebView2 原生销毁并非同步完成，那样会在短时间内超过上限，重新制造
/// CompositionController 创建/销毁风暴。
class EmbeddedBrowserControllerPool {
  EmbeddedBrowserControllerPool._();

  static final instance = EmbeddedBrowserControllerPool._();
  static const int maxControllers = 3;

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<EmbeddedBrowserLease> _leases = [];
  int _nextId = 0;
  bool _suspended = false;
  Future<void>? _drainFuture;

  EmbeddedBrowserLease? tryAcquire({
    required EmbeddedBrowserPriority priority,
    required VoidCallback onRevoked,
  }) {
    if (_suspended) return null;
    if (_leases.length >= maxControllers) return null;

    final lease = EmbeddedBrowserLease._(
      this,
      id: ++_nextId,
      priority: priority,
      onRevoked: onRevoked,
    );
    _leases.add(lease);
    revision.value++;
    return lease;
  }

  void _release(EmbeddedBrowserLease lease) {
    if (_leases.remove(lease)) revision.value++;
  }

  /// 登录、CF 验证等关键 WebView 开始前撤下帖子内全部 Controller。
  ///
  /// Flutter Widget 消失不代表 WebView2 原生 Controller 已同步销毁，必须
  /// 留出冷却窗口，避免验证 WebView与正在析构的平台视图重叠。
  Future<void> suspendAndDrain() {
    if (!_suspended) {
      _suspended = true;
      final revoked = List<EmbeddedBrowserLease>.of(_leases);
      _leases.clear();
      for (final lease in revoked) {
        lease._revoke();
      }
      revision.value++;
      _drainFuture = revoked.isEmpty
          ? Future<void>.value()
          : Future<void>.delayed(const Duration(milliseconds: 750));
    }
    return _drainFuture ?? Future<void>.value();
  }

  void resume() {
    if (!_suspended) return;
    _suspended = false;
    _drainFuture = null;
    revision.value++;
  }

  /// 当前活跃槽位数，供运行时假死诊断与测试读取。
  int get activeCount => _leases.length;

  /// 池是否因登录/CF 等关键浏览器操作而暂停。
  bool get suspended => _suspended;
}
