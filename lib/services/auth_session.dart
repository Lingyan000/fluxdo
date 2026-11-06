import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 全局会话代管理器
/// 每次登录/登出状态变更时递增 generation，所有旧请求自动失效
class AuthSession {
  static final AuthSession _instance = AuthSession._internal();
  factory AuthSession() => _instance;
  AuthSession._internal();

  int _generation = 0;

  /// 浏览器运行时据此弃用旧页面，避免跨账号保留 JS 状态。
  final ValueNotifier<int> generationChanges = ValueNotifier<int>(0);
  CancelToken _cancelToken = CancelToken();

  /// 当前会话代
  int get generation => _generation;

  /// 当前会话的 CancelToken（供 Dio 请求携带）
  CancelToken get cancelToken => _cancelToken;

  /// 推进到新的会话代，取消所有旧请求
  /// 返回新的 generation
  int advance() {
    _generation++;
    // 取消所有携带旧 CancelToken 的请求
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('[AuthSession] 会话代变更: $_generation');
    }
    _cancelToken = CancelToken();
    generationChanges.value = _generation;
    debugPrint('[AuthSession] 推进到 generation=$_generation');
    return _generation;
  }

  /// 检查给定的 generation 是否仍然有效
  bool isValid(int gen) => gen == _generation;
}
