/// Exact-origin app routes only; subdomains and internal runtime URLs do not
/// identify user-facing applications.
class MiniAppUrl {
  static final _id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static bool validId(String id) => _id.hasMatch(id);

  static Uri? parse(String value, String site) {
    final base = Uri.tryParse(site);
    final input = Uri.tryParse(value);
    if (base == null || input == null || value.contains('\\')) return null;
    final uri = base.resolveUri(input);
    if (uri.scheme != base.scheme ||
        uri.host != base.host ||
        uri.port != base.port ||
        uri.userInfo.isNotEmpty ||
        !{'https', 'http'}.contains(uri.scheme)) {
      return null;
    }
    final prefix = base.path.replaceFirst(RegExp(r'/$'), '');
    final path = uri.path;
    if (path == '$prefix/apps' || path == '$prefix/apps/') return uri;
    if (!path.startsWith('$prefix/apps/')) return null;
    final id = path.substring('$prefix/apps/'.length);
    return validId(id) ? uri : null;
  }

  static String? appId(Uri uri) {
    final last = uri.pathSegments.lastOrNull;
    return last != null && validId(last) ? last : null;
  }

  static Uri embed(String value, String appId, String site) {
    final uri = parse(value, site);
    if (uri == null || MiniAppUrl.appId(uri) != appId) {
      throw const FormatException('Invalid mini-app entry URL');
    }
    return uri.replace(
      queryParameters: {
        ...uri.queryParametersAll,
        'embed_mode': ['true'],
      },
    );
  }
}
