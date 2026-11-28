import 'dart:async';
import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../providers/theme_provider.dart';
import '../../utils/link_launcher.dart' show isInternalUrl, launchExternalLink;
import '../../widgets/common/app_bottom_sheet.dart';
import 'core/metaverse_link_rule.dart';
import 'core/metaverse_service.dart';
import 'metaverse_registry.dart';

/// 偏好只存域名与服务 ID；服务失效时清理，浏览器偏好保留至该域名无可用服务。
final metaverseLinkDefaultsProvider =
    NotifierProvider<MetaverseLinkDefaults, Map<String, String>>(
      MetaverseLinkDefaults.new,
    );

class MetaverseLinkDefaults extends Notifier<Map<String, String>> {
  static const preferenceKey = 'metaverse_link_defaults_v1';
  static const browser = '@browser';
  Future<void> _writes = Future.value();

  Map<String, String> _prune(Map<String, String> values) {
    final services = ref.read(metaverseServicesProvider);
    return {
      for (final e in values.entries)
        if (services.any(
          (service) =>
              (e.value == browser || service.id == e.value) &&
              service.isEnabled(ref.container) &&
              service.linkRules.any(
                (rule) => MetaverseHostPattern.matches(rule.host, e.key),
              ),
        ))
          e.key: e.value,
    };
  }

  Future<void> _persist(Map<String, String> values) {
    final prefs = ref.read(sharedPreferencesProvider);
    final encoded = jsonEncode(values);
    // 按调用次序落盘，旧保存不能在重置或停用清理之后覆盖新结果。
    final write = _writes.then((_) async {
      if (!await prefs.setString(preferenceKey, encoded)) {
        throw StateError('link_preference_save_failed');
      }
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

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
    ref.listen(metaverseServicesProvider, (_, _) {
      final next = _prune(state);
      if (next.length != state.length) {
        state = next;
        // 失效选择不因落盘失败恢复；下次载入仍会按有效规则过滤。
        unawaited(_persist(next).catchError((Object _) {}));
      }
    });
    final next = _prune(values);
    if (next.length != values.length) {
      unawaited(_persist(next).catchError((Object _) {}));
    }
    return next;
  }

  Future<void> remember(String host, String? service) async {
    final next = {...state}..remove(host.toLowerCase());
    if (service != null) next[host.toLowerCase()] = service;
    while (next.length > 128) {
      next.remove(next.keys.first);
    }
    await _save(_prune(next));
  }

  Future<void> clearAll() => _save({});

  Future<void> _save(Map<String, String> next) async {
    var previous = state;
    final changes = ref.listen(metaverseServicesProvider, (_, _) {
      // 失效一旦发生就从回滚快照移除，期间重新启用也不恢复旧选择。
      previous = _prune(previous);
    });
    // 先发布当前选择；保存期间撤权或停用产生的清理不能被旧异步结果覆盖。
    state = next;
    try {
      await _persist(next);
    } catch (_) {
      if (ref.mounted && identical(state, next)) {
        // 重置期间可能停用服务；回滚也不能重新带回失效的选择。
        state = _prune(previous);
        // SharedPreferences 会先更新内存缓存，同步纠正缓存与持久化值。
        await _persist(state).catchError((Object _) {});
      }
      rethrow;
    } finally {
      changes.close();
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
