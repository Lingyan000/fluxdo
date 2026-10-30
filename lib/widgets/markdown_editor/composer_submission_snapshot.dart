import 'package:flutter/foundation.dart';

import '../../services/toast_service.dart';

/// 校验/确认只批准这一份参数。异步等待后必须先同步编辑器再比较，
/// 不可用最新正文替换已批准正文，否则会绕过字数或插件校验。
/// 参数使用标量，列表参数需展开，避免保存可变列表的引用。
class ComposerSubmissionSnapshot {
  ComposerSubmissionSnapshot(List<Object?> values)
    : _values = List<Object?>.unmodifiable(values);

  final List<Object?> _values;

  static const retryMessage = '内容在确认期间发生变化，已保留最新编辑，请重新提交';

  bool verify({
    required bool Function() synchronize,
    required List<Object?> Function() read,
  }) {
    if (!synchronize()) return false;
    if (listEquals(_values, read())) return true;
    ToastService.showInfo(retryMessage);
    return false;
  }
}
