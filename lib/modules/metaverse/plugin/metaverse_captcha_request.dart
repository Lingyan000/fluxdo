import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../core/metaverse_link_rule.dart';
import 'metaverse_plugin_manifest.dart';

enum MetaverseCaptchaProvider { hcaptcha }

class MetaverseCaptchaRequest {
  const MetaverseCaptchaRequest(this.provider, this.origin, this.siteKey);
  final MetaverseCaptchaProvider provider;
  final Uri origin;
  final String siteKey;
  static MetaverseCaptchaRequest parse(
    MetaversePluginManifest manifest,
    Map<String, Object?> params,
  ) {
    final provider = MetaverseCaptchaProvider.values
        .where((p) => p.name == params['provider'])
        .firstOrNull;
    final uri = params['origin'] is String
        ? Uri.tryParse(params['origin'] as String)
        : null;
    final key = params['siteKey'];
    if (!manifest.requiredFeatures.contains('captchaChallenge') ||
        provider == null ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !MetaverseHostPattern.matchesAny(manifest.networkHosts, uri.host) ||
        key is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(key)) {
      throw const MetaversePluginCallException('captcha_request_invalid');
    }
    return MetaverseCaptchaRequest(provider, Uri.parse(uri.origin), key);
  }
}
