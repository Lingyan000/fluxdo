/// Safari 产品版本用于 iOS UA 的主、次版本；拒绝空值和非数字版本。
/// 调用方只能传入 Safari Bundle 的 CFBundleShortVersionString。
String? iosSafariUserAgentVersion(String? safariProductVersion) {
  if (safariProductVersion == null) return null;
  final match = RegExp(r'^(\d+)\.(\d+)(?:\.\d+)*$')
      .firstMatch(safariProductVersion.trim());
  return match == null ? null : '${match.group(1)}.${match.group(2)}';
}

/// 使用 Safari 本身的版本补齐 WKWebView UA；读取失败时保留既有登录兼容回退。
String completeIosUserAgent(String ua, {String? safariProductVersion}) {
  if (ua.contains('Safari/')) return ua;
  final legacy = RegExp(r'CPU (?:iPhone )?OS (\d+)[_\.](\d+)')
      .firstMatch(ua);
  final version = iosSafariUserAgentVersion(safariProductVersion) ??
      (legacy == null ? '18.0' : '${legacy.group(1)}.${legacy.group(2)}');
  final completed = ua.contains('Version/')
      ? ua
      : ua.replaceFirst('Mobile/', 'Version/$version Mobile/');
  return '$completed Safari/604.1';
}
