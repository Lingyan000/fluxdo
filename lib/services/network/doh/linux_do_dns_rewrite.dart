import 'dart:io';

enum LinuxDoDnsRewriteTargetType { a, aaaa, frontDomain }

class LinuxDoDnsRewriteTarget {
  const LinuxDoDnsRewriteTarget({required this.value, required this.type});

  final String value;
  final LinuxDoDnsRewriteTargetType type;

  bool get isAddress => type != LinuxDoDnsRewriteTargetType.frontDomain;
  bool get isFrontDomain => type == LinuxDoDnsRewriteTargetType.frontDomain;
}

/// `linux.do` 通配连接改写规则。
///
/// A/AAAA 目标只替换连接 IP；域名目标用于域前置，由 rhttp 将 TLS SNI
/// 切换为前置域名，同时保持 HTTP Host 为原始 `*.linux.do`。
class LinuxDoDnsRewrite {
  const LinuxDoDnsRewrite._();

  static const sourceDomain = 'linux.do';

  static bool matchesHost(String host) {
    final normalized = host.trim().toLowerCase().replaceFirst(
      RegExp(r'\.$'),
      '',
    );
    return normalized == sourceDomain || normalized.endsWith('.$sourceDomain');
  }

  static LinuxDoDnsRewriteTarget? parseTarget(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;

    final address = InternetAddress.tryParse(value);
    if (address != null) {
      return LinuxDoDnsRewriteTarget(
        value: address.address,
        type: address.type == InternetAddressType.IPv6
            ? LinuxDoDnsRewriteTargetType.aaaa
            : LinuxDoDnsRewriteTargetType.a,
      );
    }

    final host = value.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.length > 253 || !host.contains('.')) return null;
    final labels = host.split('.');
    final validLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    if (labels.any((label) => !validLabel.hasMatch(label))) return null;

    return LinuxDoDnsRewriteTarget(
      value: host,
      type: LinuxDoDnsRewriteTargetType.frontDomain,
    );
  }
}

/// 构造域前置所需的传输 URL 与原始 Host。
class LinuxDoDomainFronting {
  const LinuxDoDomainFronting._();

  static Uri rewriteUri(Uri original, String frontDomain) {
    return original.replace(host: frontDomain);
  }

  static String originalHostHeader(Uri original) {
    final defaultPort = switch (original.scheme.toLowerCase()) {
      'http' => 80,
      'https' => 443,
      _ => null,
    };
    if (!original.hasPort || original.port == defaultPort) {
      return original.host;
    }
    return '${original.host}:${original.port}';
  }
}
