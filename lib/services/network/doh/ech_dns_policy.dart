/// 公共 ECH 入口策略；仅替换 DNS 查询名，保留真实 Host、SNI 和缓存键。
class EchDnsPolicy {
  const EchDnsPolicy({this.enabled = true, this.customDomains = const []});

  static const cloudflareQueryName = 'cloudflare-ech.com';
  static const builtinDomains = ['linux.do', 'ldstatic.com'];

  final bool enabled;
  final List<String> customDomains;

  EchDnsPolicy copyWith({bool? enabled, List<String>? customDomains}) =>
      EchDnsPolicy(
        enabled: enabled ?? this.enabled,
        customDomains: List.unmodifiable(customDomains ?? this.customDomains),
      );

  static String normalizeDomain(String value) =>
      value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  /// 只接收完整主机名，不接受 URL、端口、IP 或通配符。
  static bool isValidDomain(String value) {
    final host = normalizeDomain(value);
    if (host.length > 253 ||
        !host.contains('.') ||
        RegExp(r'^[0-9.]+$').hasMatch(host)) {
      return false;
    }
    return host
        .split('.')
        .every(
          (label) =>
              label.isNotEmpty &&
              label.length <= 63 &&
              RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
        );
  }

  static bool covers(String domain, String host) =>
      host == domain || host.endsWith('.$domain');

  String queryName(String host) {
    if (!enabled) return host;
    final normalized = normalizeDomain(host);
    for (final domain in [...builtinDomains, ...customDomains]) {
      if (covers(domain, normalized)) return cloudflareQueryName;
    }
    return host;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'custom_domains': customDomains,
  };

  factory EchDnsPolicy.fromJson(Map<String, dynamic> json) {
    final domains = <String>{};
    for (final value in json['custom_domains'] as List? ?? const []) {
      if (value is! String || !isValidDomain(value)) continue;
      final domain = normalizeDomain(value);
      if (!builtinDomains.any((builtin) => covers(builtin, domain))) {
        domains.add(domain);
      }
    }
    return EchDnsPolicy(
      enabled: json['enabled'] as bool? ?? true,
      customDomains: List.unmodifiable(domains),
    );
  }
}
