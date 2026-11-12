import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';
import '../plugin/metaverse_plugin_manifest.dart';

class MetaverseMarketSource {
  const MetaverseMarketSource(this.url, {this.enabled = true});
  static const defaultUrl =
      'https://raw.githubusercontent.com/Lingyan000/fluxdo-plugins/main/index.json';
  final String url;
  final bool enabled;
  String get id => url;

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
  });
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
  final List<String> categories, screenshots;
  final MetaverseMarketSource source;
  bool get compatible => MetaversePluginManifest.supportedApiVersions.contains(apiVersion);
  bool newerThan(String installed) =>
      PluginVersion.parse(version).compareTo(PluginVersion.parse(installed)) >
      0;

  factory MetaverseMarketEntry.parse(
    Object? value,
    MetaverseMarketSource source,
  ) {
    if (value is! Map<String, dynamic>) throw const FormatException('插件条目无效');
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
    final digest = text('sha256', max: 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('插件摘要无效');
    }
    final api = value['apiVersion'];
    if (api is! int || api < 1) throw const FormatException('插件 API 版本无效');
    final screenshots = strings('screenshots', max: 8);
    for (final url in screenshots) {
      MetaverseMarketSource.httpsUri(url);
    }
    return MetaverseMarketEntry(
      id: id,
      name: text('name', max: 100),
      version: version,
      summary: text('summary', max: 512),
      description: text('description', max: 65536, optional: true),
      author: text('author', max: 100),
      repository: MetaverseMarketSource.httpsUri(text('repository')).toString(),
      packageUrl: MetaverseMarketSource.httpsUri(text('packageUrl')).toString(),
      sha256: digest,
      apiVersion: api,
      categories: strings('categories'),
      screenshots: screenshots,
      changelog: text('changelog', max: 32768, optional: true),
      icon: value['icon'] is String ? text('icon', max: 64) : null,
      source: source,
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
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('市场包含重复插件 ID');
    }
    return MetaverseMarketCatalog(
      value['name'] as String,
      List.unmodifiable(entries),
    );
  }
}
