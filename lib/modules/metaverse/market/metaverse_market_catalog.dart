import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import '../plugin/metaverse_plugin_manifest.dart';
import '../plugin/metaverse_manifest_localization.dart';
import '../plugin/metaverse_plugin_permission.dart';
import '../core/metaverse_link_rule.dart';

/// 目录提供的预览，下载后必须与包内清单再次核对。
class MetaverseMarketPermissions {
  const MetaverseMarketPermissions(this.permissions, this.networkHosts, this.linkHosts);
  final Set<MetaversePluginPermission> permissions;
  final List<String> networkHosts, linkHosts;
  factory MetaverseMarketPermissions.parse(Object? value) {
    if (value is! Map || value.keys.any((k) => !{'permissions', 'networkHosts', 'linkHosts'}.contains(k))) {
      throw const FormatException('市场权限摘要无效');
    }
    List<String> list(String key, {bool host = false}) {
      final values = value[key];
      if (values is! List || values.length > 32 || values.any((v) => v is! String || v.length > 253 ||
          (host && MetaverseHostPattern.normalize(v) == null)) || values.toSet().length != values.length) {
        throw const FormatException('市场权限摘要无效');
      }
      return List<String>.unmodifiable(values);
    }
    final names = list('permissions');
    final permissions = MetaversePluginPermission.values.where((p) => names.contains(p.name)).toSet();
    if (permissions.length != names.length) throw const FormatException('市场权限类型无效');
    return MetaverseMarketPermissions(permissions, list('networkHosts', host: true), list('linkHosts', host: true));
  }
  bool matches(MetaversePluginManifest manifest) =>
      permissions.length == manifest.declaredPermissions.length &&
      permissions.containsAll(manifest.declaredPermissions) &&
      networkHosts.toSet().containsAll(manifest.networkHosts) && networkHosts.length == manifest.networkHosts.length &&
      linkHosts.toSet().containsAll(manifest.linkHosts) && linkHosts.length == manifest.linkHosts.length;
}

class MetaverseMarketSource {
  const MetaverseMarketSource(this.url, {this.enabled = true});
  static const defaultUrl =
      'https://raw.githubusercontent.com/Lingyan000/fluxdo-plugins/main/index.json';
  final String url;
  final bool enabled;
  String get id => url;
  String get displayName {
    final uri = Uri.parse(url);
    if (uri.host == 'raw.githubusercontent.com' && uri.pathSegments.length >= 4) {
      return uri.pathSegments.take(2).join('/');
    }
    return uri.host;
  }

  static Uri httpsUri(Object? raw) {
    final uri = raw is String && raw.length <= 4096 ? Uri.tryParse(raw) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasFragment) {
      throw const FormatException('需要有效的 HTTPS 地址');
    }
    return uri;
  }

  factory MetaverseMarketSource.fromInput(String input) {
    var uri = httpsUri(input.trim());
    if (uri.host == 'github.com') {
      final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (parts.length < 2 || uri.hasQuery) {
        throw const FormatException('GitHub 仓库地址无效');
      }
      final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
      var ref = 'main';
      var path = <String>['index.json'];
      if (parts.length > 2) {
        if (parts.length < 4 || (parts[2] != 'tree' && parts[2] != 'blob')) {
          throw const FormatException('需要仓库或索引文件地址');
        }
        ref = parts[3];
        path = parts.skip(4).toList();
        if (path.isEmpty || !path.last.endsWith('.json')) {
          path.add('index.json');
        }
      }
      uri = Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        pathSegments: [parts[0], repo, ref, ...path],
      );
    } else if (uri.path.endsWith('/')) {
      uri = uri.resolve('index.json');
    }
    if (uri.hasQuery || !uri.path.endsWith('.json')) {
      throw const FormatException('需要 index.json 文件地址');
    }
    return MetaverseMarketSource(uri.toString());
  }

  Map<String, Object> toJson() => {'url': url, 'enabled': enabled};
}

class MetaverseMarketEntry {
  const MetaverseMarketEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.summary,
    required this.description,
    required this.author,
    required this.repository,
    required this.packageUrl,
    required this.sha256,
    required this.categories,
    required this.screenshots,
    required this.changelog,
    required this.apiVersion,
    required this.source,
    this.icon,
    this.requiredFeatures = const [],
    this.channel = 'stable',
    this.withdrawn = false,
    this.withdrawnVersions = const [],
    this.reason = '',
    this.locales = const {},
    this.permissionsSummary,
    this.publisherKeyFingerprint,
    this.publisherPreviewAvailable = false,
  });
  final MetaverseMarketPermissions? permissionsSummary;
  final String? publisherKeyFingerprint;
  final bool publisherPreviewAvailable;
  final String id,
      name,
      version,
      summary,
      description,
      author,
      repository,
      packageUrl,
      sha256,
      changelog;
  final String? icon;
  final int apiVersion;
  final List<String> requiredFeatures;
  final List<String> categories, screenshots;
  final String channel, reason;
  final bool withdrawn;
  final List<String> withdrawnVersions;
  final MetaverseMarketSource source;
  final Map<String, dynamic> locales;
  String localized(String key, String locale) => MetaverseManifestLocalization.text(
    {'locales':locales}, key, switch(key) {
      'name' => name, 'summary' => summary, 'description' => description, 'changelog' => changelog,
      _ => throw ArgumentError.value(key),
    }, locale);
  bool get compatible => !withdrawn && MetaversePluginManifest.supportedApiVersions.contains(apiVersion) && PluginFeatures.missing(requiredFeatures).isEmpty;
  bool newerThan(String installed) =>
      PluginVersion.parse(version).compareTo(PluginVersion.parse(installed)) >
      0;

  factory MetaverseMarketEntry.parse(
    Object? value,
    MetaverseMarketSource source,
  ) {
    if (value is! Map<String, dynamic>) throw const FormatException('插件条目无效');
    MetaverseManifestLocalization.validateFields(value['locales'], const {'name':100,'summary':512,'description':65536,'changelog':32768});
    String text(String key, {int max = 4096, bool optional = false}) {
      final result = value[key];
      if (optional && result == null) return '';
      if (result is! String || result.isEmpty || result.length > max) {
        throw FormatException('插件字段无效 $key');
      }
      return result;
    }

    List<String> strings(String key, {int max = 16}) {
      final list = value[key] ?? <String>[];
      if (list is! List ||
          list.length > max ||
          list.any((v) => v is! String || v.length > 4096)) {
        throw FormatException('插件字段无效 $key');
      }
      return List<String>.unmodifiable(list);
    }

    final id = text('id', max: 64);
    if (!RegExp(r'^[a-z0-9]+([._-][a-z0-9]+)+$').hasMatch(id)) {
      throw const FormatException('插件 ID 无效');
    }
    final version = text('version', max: 64);
    PluginVersion.parse(version);
    final channel = value['channel'] ?? (PluginVersion.parse(version).prerelease.isEmpty ? 'stable' : 'preview');
    if (channel != 'stable' && channel != 'preview') throw const FormatException('发布渠道无效');
    if (channel == 'stable' && PluginVersion.parse(version).prerelease.isNotEmpty) throw const FormatException('测试版本不能声明稳定渠道');
    final withdrawnVersions = strings('withdrawnVersions', max: 128);
    for (final v in withdrawnVersions) { PluginVersion.parse(v); }
    if (value.containsKey('withdrawn') && value['withdrawn'] is! bool) throw const FormatException('撤回标记无效');
    final digest = text('sha256', max: 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('插件摘要无效');
    }
    final api = value['apiVersion'];
    if (api is! int || api < 1) throw const FormatException('插件 API 版本无效');
    final screenshots = strings('screenshots', max: 8);
    final fingerprint = value['publisherKeyFingerprint'];
    if (fingerprint != null && (fingerprint is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint))) {
      throw const FormatException('市场发布者指纹无效');
    }
    for (final url in screenshots) {
      MetaverseMarketSource.httpsUri(url);
    }
    return MetaverseMarketEntry(
      id: id,
      name: text('name', max: 100),
      version: version,
      channel: channel as String,
      withdrawn: value['withdrawn'] == true || withdrawnVersions.contains(version),
      withdrawnVersions: withdrawnVersions,
      reason: text('reason', max: 1024, optional: true),
      summary: text('summary', max: 512),
      description: text('description', max: 65536, optional: true),
      author: text('author', max: 100),
      repository: MetaverseMarketSource.httpsUri(text('repository')).toString(),
      packageUrl: MetaverseMarketSource.httpsUri(text('packageUrl')).toString(),
      sha256: digest,
      apiVersion: api,
      requiredFeatures: PluginFeatures.parse(value['requiredFeatures']),
      categories: strings('categories'),
      screenshots: screenshots,
      changelog: text('changelog', max: 32768, optional: true),
      icon: value['icon'] is String ? text('icon', max: 64) : null,
      source: source,
      permissionsSummary: value['permissionsSummary'] == null ? null : MetaverseMarketPermissions.parse(value['permissionsSummary']),
      publisherKeyFingerprint: fingerprint as String?,
      publisherPreviewAvailable: value.containsKey('publisherKeyFingerprint'),
      locales: Map<String,dynamic>.unmodifiable(value['locales'] as Map? ?? const {}),
    );
  }
}

class MetaverseMarketCatalog {
  const MetaverseMarketCatalog(this.name, this.entries);
  final String name;
  final List<MetaverseMarketEntry> entries;

  factory MetaverseMarketCatalog.parse(
    Object? value,
    MetaverseMarketSource source,
  ) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['name'] is! String ||
        value['plugins'] is! List) {
      throw const FormatException('市场索引格式无效');
    }
    final raw = value['plugins'] as List;
    if (raw.length > 1000) throw const FormatException('市场条目数量超限');
    final entries = raw
        .map((v) => MetaverseMarketEntry.parse(v, source))
        .toList();
    if (entries.map((e) => '${e.id}:${e.channel}').toSet().length != entries.length) {
      throw const FormatException('市场包含重复插件 ID');
    }
    return MetaverseMarketCatalog(
      value['name'] as String,
      List.unmodifiable(entries),
    );
  }
}
