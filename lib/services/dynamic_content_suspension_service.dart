import 'package:flutter/foundation.dart';

/// 全局动态内容暂停闸门。
///
/// 编辑器、验证页等高负载界面可持有一个租约。只要仍有任意租约存在，帖子
/// 中的动态 SVG 就卸载播放器并保留定尺寸占位，避免后台动画与前台输入、
/// 预览渲染争抢 UI isolate 和 GPU。
class DynamicContentSuspensionService extends ChangeNotifier {
  DynamicContentSuspensionService._();

  static final DynamicContentSuspensionService instance =
      DynamicContentSuspensionService._();

  int _leaseCount = 0;

  bool get suspended => _leaseCount > 0;

  DynamicContentSuspensionLease acquire({required String reason}) {
    _leaseCount++;
    if (_leaseCount == 1) notifyListeners();
    return DynamicContentSuspensionLease._(this, reason);
  }

  void _release() {
    if (_leaseCount == 0) return;
    _leaseCount--;
    if (_leaseCount == 0) notifyListeners();
  }
}

class DynamicContentSuspensionLease {
  DynamicContentSuspensionLease._(this._owner, this.reason);

  final DynamicContentSuspensionService _owner;
  final String reason;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release();
  }
}
