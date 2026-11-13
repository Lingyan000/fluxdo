import 'package:flutter/foundation.dart';

/// 域名模式：精确域名（`example.com`）或一级通配（`*.example.com`，只匹配子域）。
///
/// 网络白名单和链接规则共用同一套语法与校验。
abstract final class MetaverseHostPattern {
  static final _pattern = RegExp(
    r'^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  );
  // 浏览器可访问含下划线的资源主机；脚本权限声明仍使用严格域名语法。
  static final _resourcePattern = RegExp(
    r'^([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z]{2,63}$',
  );

  /// 只在内网/本机解析的后缀：第三方插件不该碰用户的局域网。
  static const _privateSuffixes = {
    'local',
    'localhost',
    'internal',
    'intranet',
    'lan',
    'home',
    'corp',
    'test',
    'invalid',
  };

  /// 校验并归一化（小写）。不合法返回 null。
  ///
  /// 顶级域必须是字母，因此 IP 字面量和 `localhost` 这类单标签主机都会被拒。
  /// [reservedHosts] 是宿主站点域名：与其相同、是其子域、或通配覆盖到它的
  /// 模式一律拒绝。
  static String? normalize(
    String value, {
    List<String> reservedHosts = const [],
    bool resourceHost = false,
  }) {
    final pattern = value.trim().toLowerCase();
    final syntax = resourceHost ? _resourcePattern : _pattern;
    if (pattern.length > 253 || !syntax.hasMatch(pattern)) return null;
    final domain = pattern.startsWith('*.') ? pattern.substring(2) : pattern;
    if (_privateSuffixes.contains(domain.split('.').last)) return null;
    for (final reserved in reservedHosts) {
      final host = reserved.toLowerCase();
      if (host.isEmpty) continue;
      // 插件域名落在站点域内，或通配范围把站点域包了进去。
      if (domain == host || domain.endsWith('.$host')) return null;
      if (pattern.startsWith('*.') && host.endsWith('.$domain')) return null;
    }
    return pattern;
  }

  static bool matches(String pattern, String host) {
    final target = host.toLowerCase();
    if (pattern.startsWith('*.')) {
      return target.endsWith(pattern.substring(1));
    }
    return target == pattern;
  }

  static bool matchesAny(Iterable<String> patterns, String host) =>
      patterns.any((pattern) => matches(pattern, host));
}

/// 链接规则：声明某类外部链接由服务的哪个页面接管。
///
/// 匹配完全是声明式的（域名 + 路径模式），不执行插件脚本——帖子里每点一次
/// 链接都会过一遍规则，不能为此启动脚本运行时。
///
/// 路径模式按 `/` 分段：字面量精确匹配，`:name` 捕获一段，末尾的 `*` 捕获
/// 剩余全部（参数名 `rest`）。
@immutable
class MetaverseLinkRule {
  const MetaverseLinkRule._(this.host, this.path, this.page, this._segments);

  /// 解析规则；[host] 须已通过 [MetaverseHostPattern.normalize]。
  /// 路径模式不合法时返回 null。
  static MetaverseLinkRule? parse({
    required String host,
    required String path,
    required String page,
  }) {
    if (!path.startsWith('/') || path.length > 256) return null;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final names = <String>{};
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment == '*') {
        if (i != segments.length - 1 || !names.add('rest')) return null;
      } else if (segment.startsWith(':')) {
        final name = segment.substring(1);
        if (!_paramName.hasMatch(name) || !names.add(name)) return null;
      } else if (segment.contains('*') || segment.contains(':')) {
        return null;
      }
    }
    return MetaverseLinkRule._(host, path, page, List.unmodifiable(segments));
  }

  static final _paramName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,31}$');

  /// 域名模式，见 [MetaverseHostPattern]。
  final String host;

  /// 路径模式原文。
  final String path;

  /// 目标页面 id。
  final String page;

  final List<String> _segments;

  /// 匹配成功返回捕获到的路径参数，否则返回 null。
  Map<String, String>? match(Uri uri) {
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    if (!MetaverseHostPattern.matches(host, uri.host)) return null;
    final actual = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final params = <String, String>{};
    for (var i = 0; i < _segments.length; i++) {
      final expected = _segments[i];
      if (expected == '*') {
        params['rest'] = actual.sublist(i).join('/');
        return params;
      }
      if (i >= actual.length) return null;
      if (expected.startsWith(':')) {
        params[expected.substring(1)] = actual[i];
      } else if (expected != actual[i]) {
        return null;
      }
    }
    return actual.length == _segments.length ? params : null;
  }
}
