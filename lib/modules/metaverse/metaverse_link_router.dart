import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/metaverse_service.dart';
import 'metaverse_registry.dart';
import '../../utils/link_launcher.dart' show isInternalUrl;

/// 帖内链接是否由某个已开启的元宇宙服务接管。
///
/// 只看已开启服务声明的 http(s) 规则；官方服务可接管自己的子域，第三方
/// 不覆盖论坛内链。匹配纯靠清单里的静态规则，不启动脚本。
///
/// 返回 false 表示没有服务接管，调用方按原有逻辑继续。
Future<bool> openMetaverseLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final match = matchMetaverseLink(container, uri);
  if (match == null) return false;
  await match.service.openPage(context, match.page, {
    ...match.params,
    // 原始链接一并交给页面，页面可提供"在浏览器中打开"。
    'url': uri.toString(),
  });
  return true;
}

/// 找到接管该链接的服务与页面；没有则返回 null。
MetaverseLinkMatch? matchMetaverseLink(ProviderContainer container, Uri uri) {
  for (final service in container.read(metaverseServicesProvider)) {
    final rules = service.linkRules;
    // 官方服务可以接管自己的子域；第三方仍不能覆盖论坛内链。
    if (service.isThirdParty && isInternalUrl(uri)) continue;
    if (rules.isEmpty || !service.isEnabled(container)) continue;
    for (final rule in rules) {
      final params = rule.match(uri);
      if (params != null) {
        return MetaverseLinkMatch(service, rule.page, params);
      }
    }
  }
  return null;
}

class MetaverseLinkMatch {
  const MetaverseLinkMatch(this.service, this.page, this.params);

  final MetaverseService service;
  final String page;
  final Map<String, String> params;
}
