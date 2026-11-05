/// 由 User-Agent 推导与真实浏览器一致的 User-Agent Client Hints 请求头。
///
/// 浏览器默认只发送三个低熵头（`sec-ch-ua` / `sec-ch-ua-mobile` /
/// `sec-ch-ua-platform`），高熵头只在服务端通过 `Accept-CH` 索取后才发送；
/// 品牌列表按 Chromium 的规则以大版本号为种子生成 GREASE 品牌和排列顺序。
/// 非 Chromium 内核（Safari / WebKit）不支持 Client Hints，返回 null。
class ClientHints {
  ClientHints._();

  static final RegExp _chromeMajor = RegExp(r'Chrome/(\d+)');

  // 与 Chromium 生成 GREASE 品牌所用的字符表、版本表、排列表一致
  static const List<String> _greaseyChars = [
    ' ', '(', ':', '-', '.', '/', ')', ';', '=', '?', '_', //
  ];
  static const List<String> _greasedVersions = ['8', '99', '24'];
  static const List<List<int>> _orders = [
    [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0], //
  ];

  /// 推导 Client Hints 请求头；UA 不是 Chromium 内核时返回 null。
  static Map<String, String>? fromUserAgent(String userAgent) {
    final match = _chromeMajor.firstMatch(userAgent);
    if (match == null) return null;
    final major = int.parse(match.group(1)!);

    return {
      'sec-ch-ua': brandList(major, _brandOf(userAgent)),
      'sec-ch-ua-mobile': userAgent.contains(' Mobile') ? '?1' : '?0',
      'sec-ch-ua-platform': '"${_platformOf(userAgent)}"',
    };
  }

  /// 按 Chromium 规则生成 `sec-ch-ua` 品牌列表。
  static String brandList(int major, String brand) {
    final greaseyBrand =
        'Not${_greaseyChars[major % _greaseyChars.length]}A'
        '${_greaseyChars[(major + 1) % _greaseyChars.length]}Brand';
    final order = _orders[major % _orders.length];
    final slots = List<String>.filled(3, '');
    slots[order[0]] =
        '"$greaseyBrand";v="${_greasedVersions[major % _greasedVersions.length]}"';
    slots[order[1]] = '"Chromium";v="$major"';
    slots[order[2]] = '"$brand";v="$major"';
    return slots.join(', ');
  }

  static String _brandOf(String userAgent) {
    if (userAgent.contains('Edg/')) return 'Microsoft Edge';
    if (RegExp(r';\s*wv\)').hasMatch(userAgent)) return 'Android WebView';
    return 'Google Chrome';
  }

  static String _platformOf(String userAgent) {
    if (userAgent.contains('Android')) return 'Android';
    if (userAgent.contains('Windows')) return 'Windows';
    if (userAgent.contains('Macintosh')) return 'macOS';
    if (userAgent.contains('CrOS')) return 'Chrome OS';
    if (userAgent.contains('Linux')) return 'Linux';
    return 'Unknown';
  }
}
