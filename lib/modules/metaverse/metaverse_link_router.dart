import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/theme_provider.dart';
import '../../utils/link_launcher.dart' show isInternalUrl, launchExternalLink;
import '../../widgets/common/app_bottom_sheet.dart';
import 'core/metaverse_service.dart';
import 'metaverse_registry.dart';
import 'plugin/metaverse_plugin_service.dart';

/// 偏好只存域名与服务 ID；停用或撤销链接权限即清理，重新启用不恢复旧选择。
final metaverseLinkDefaultsProvider =
    NotifierProvider<MetaverseLinkDefaults, Map<String, String>>(
      MetaverseLinkDefaults.new,
    );

class MetaverseLinkDefaults extends Notifier<Map<String, String>> {
  static const preferenceKey = 'metaverse_link_defaults_v1';
  static const browser = '@browser';

  @override
  Map<String, String> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    var values = <String, String>{};
    try {
      final raw = jsonDecode(prefs.getString(preferenceKey) ?? '{}');
      if (raw is Map && raw.length <= 128) {
        values = {
          for (final e in raw.entries)
            if (e.key is String && e.key.length <= 253 && e.value is String)
              e.key as String: e.value as String,
        };
      }
    } catch (_) {}
    Map<String, String> prune(Map<String, String> old) => {
      for (final e in old.entries)
        if (e.value == browser ||
            ref
                .read(metaverseServicesProvider)
                .any(
                  (s) =>
                      s.id == e.value &&
                      s.linkRules.isNotEmpty &&
                      (s is! MetaversePluginService || s.plugin.enabled),
                ))
          e.key: e.value,
    };
    ref.listen(metaverseServicesProvider, (_, _) {
      final next = prune(state);
      if (next.length != state.length) {
        state = next;
        prefs.setString(preferenceKey, jsonEncode(next));
      }
    });
    final next = prune(values);
    if (next.length != values.length) {
      prefs.setString(preferenceKey, jsonEncode(next));
    }
    return next;
  }

  Future<void> remember(String host, String? service) async {
    final previous = state;
    final next = {...state}..remove(host.toLowerCase());
    if (service != null) next[host.toLowerCase()] = service;
    while (next.length > 128) {
      next.remove(next.keys.first);
    }
    // 先发布当前选择；保存期间撤权或停用产生的清理不能被旧异步结果覆盖。
    state = next;
    try {
      if (!await ref
          .read(sharedPreferencesProvider)
          .setString(preferenceKey, jsonEncode(next))) {
        throw StateError('link_preference_save_failed');
      }
    } catch (_) {
      if (ref.mounted && identical(state, next)) state = previous;
      rethrow;
    }
  }
}

/// 匹配静态规则，不运行脚本；第三方插件不接管论坛内链。
List<MetaverseLinkMatch> matchAllMetaverseLinks(
  ProviderContainer container,
  Uri uri,
) {
  final matches = <MetaverseLinkMatch>[];
  for (final service in container.read(metaverseServicesProvider)) {
    if ((service.isThirdParty && isInternalUrl(uri)) ||
        !service.isEnabled(container)) {
      continue;
    }
    for (final rule in service.linkRules) {
      final params = rule.match(uri);
      if (params != null) {
        matches.add(MetaverseLinkMatch(service, rule.page, params));
        break;
      }
    }
  }
  return matches;
}

MetaverseLinkMatch? matchMetaverseLink(ProviderContainer container, Uri uri) =>
    matchAllMetaverseLinks(container, uri).firstOrNull;

Future<bool> openMetaverseLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.host.isEmpty ||
      !{'http', 'https'}.contains(uri.scheme)) {
    return false;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final matches = matchAllMetaverseLinks(container, uri);
  if (matches.isEmpty) return false;
  final defaults = container.read(metaverseLinkDefaultsProvider);
  String? chosen = matches.length == 1
      ? matches.single.service.id
      : defaults[uri.host.toLowerCase()];
  if (chosen != MetaverseLinkDefaults.browser &&
      !matches.any((m) => m.service.id == chosen)) {
    chosen = null;
  }
  if (chosen == null) {
    final selection = await AppBottomSheet.show<({String id, bool remember})>(
      context: context,
      title: context.l10n.metaverse_chooseLink,
      contentPadding: EdgeInsets.zero,
      builder: (_) => _LinkChooser(matches: matches, host: uri.host),
    );
    // 取消选择仍消费点击，不意外打开浏览器。
    if (selection == null || !context.mounted) return true;
    chosen = selection.id;
    final fresh = matchAllMetaverseLinks(container, uri);
    if (chosen != MetaverseLinkDefaults.browser &&
        !fresh.any((m) => m.service.id == chosen)) {
      return true;
    }
    if (selection.remember) {
      await container
          .read(metaverseLinkDefaultsProvider.notifier)
          .remember(uri.host, chosen);
    }
  }
  if (!context.mounted) return true;
  if (chosen == MetaverseLinkDefaults.browser) {
    await launchExternalLink(context, url);
  } else {
    final match = matchAllMetaverseLinks(
      container,
      uri,
    ).where((m) => m.service.id == chosen).firstOrNull;
    if (match != null) {
      await match.service.openPage(context, match.page, {
        ...match.params,
        'url': url,
      });
    }
  }
  return true;
}

class _LinkChooser extends StatefulWidget {
  const _LinkChooser({required this.matches, required this.host});
  final List<MetaverseLinkMatch> matches;
  final String host;
  @override
  State<_LinkChooser> createState() => _LinkChooserState();
}

class _LinkChooserState extends State<_LinkChooser> {
  bool remember = false;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedCardGroup(
          children: [
            for (final match in widget.matches)
              ListTile(
                leading: Icon(match.service.icon),
                title: Text(match.service.title(context)),
                subtitle: Text(match.service.pageTitle(context, match.page)),
                onTap: () => Navigator.pop(context, (
                  id: match.service.id,
                  remember: remember,
                )),
              ),
            ListTile(
              leading: const Icon(Symbols.language_rounded),
              title: Text(context.l10n.metaverse_linkBrowser),
              onTap: () => Navigator.pop(context, (
                id: MetaverseLinkDefaults.browser,
                remember: remember,
              )),
            ),
          ],
        ),
        const SizedBox(height: 12),
        M3eSwitchListTile(
          title: Text(context.l10n.metaverse_rememberLink),
          subtitle: Text(widget.host),
          value: remember,
          onChanged: (value) => setState(() => remember = value),
        ),
      ],
    ),
  );
}

class MetaverseLinkMatch {
  const MetaverseLinkMatch(this.service, this.page, this.params);
  final MetaverseService service;
  final String page;
  final Map<String, String> params;
}
