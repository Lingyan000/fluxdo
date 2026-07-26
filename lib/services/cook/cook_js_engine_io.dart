/// flutter_js 引擎封装（IO 平台实现）。
///
/// 通过条件导入被 DiscourseCookService 使用；web 平台走
/// cook_js_engine_stub.dart（恒不可用）。
library;

import 'package:flutter_js/flutter_js.dart';

/// 是否支持在本平台跑 JS cook（IO 平台恒 true）。
const bool cookJsSupported = true;

/// 裸 JS 引擎薄封装：eval 代码、取字符串结果。
///
/// Android/Windows/Linux = QuickJS，iOS/macOS = JavaScriptCore（FFI 同步调用）。
class CookJsEngine {
  CookJsEngine()
    : _runtime = getJavascriptRuntime(
        // cook 管线纯字符串运算，不需要 fetch/xhr 注入
        xhr: false,
      );

  final JavascriptRuntime _runtime;

  /// eval 一段 JS，返回其字符串结果；JS 抛错/引擎错误返回 null 并携带错误。
  ///
  /// [onError] 收到错误描述（用于日志），返回 null 表示失败。
  String? evaluate(String code, {void Function(String error)? onError}) {
    try {
      final result = _runtime.evaluate(code);
      if (result.isError) {
        onError?.call(result.stringResult);
        return null;
      }
      return result.stringResult;
    } catch (e) {
      onError?.call(e.toString());
      return null;
    }
  }

  /// 销毁底层 JS runtime,释放其堆(551K bundle eval 后常驻数 MB~数十 MB)。
  /// 销毁后本实例不可再用,调用方须丢弃引用重建。
  void dispose() {
    try {
      _runtime.dispose();
    } catch (_) {
      // 引擎实现差异,失败不致命
    }
  }
}
