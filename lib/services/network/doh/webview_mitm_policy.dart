/// WebView 本地代理的 TLS 解密策略。
///
/// Windows 仅在显式启用 WebView 网络引擎时使用 MITM；高性能 rhttp
/// 模式保持端到端 TLS。其他平台继续沿用上游的 MITM 行为。
class WebViewMitmPolicy {
  const WebViewMitmPolicy._();

  static bool useMitmConnect({
    required bool isWindows,
    required bool webViewAdapterEnabled,
  }) => !isWindows || webViewAdapterEnabled;

  static bool requiresTrustedCa({
    required bool isWindows,
    required bool dohEnabled,
    required bool webViewAdapterEnabled,
  }) => isWindows && dohEnabled && webViewAdapterEnabled;
}
