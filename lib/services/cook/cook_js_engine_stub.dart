/// flutter_js 引擎封装（web stub）。
///
/// flutter_js 不支持 web，本 stub 让 DiscourseCookService 在 web 编译通过
/// 并恒定降级到 Dart fallback 预览管线。
library;

/// web 平台不支持 JS cook。
const bool cookJsSupported = false;

class CookJsEngine {
  CookJsEngine();

  String? evaluate(String code, {void Function(String error)? onError}) {
    onError?.call('cook JS engine is not supported on this platform');
    return null;
  }

  void dispose() {}
}
