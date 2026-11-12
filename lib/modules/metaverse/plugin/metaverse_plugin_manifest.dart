import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

import '../core/metaverse_link_rule.dart';
import 'metaverse_plugin_capabilities.dart';

/// 清单不合法。[field] 是出错字段的路径，[reason] 面向插件作者。
class MetaverseManifestException implements Exception {
  const MetaverseManifestException(this.field, this.reason);

  final String field;
  final String reason;

  @override
  String toString() => '$field: $reason';
}

/// 授权方式。授权一律由宿主代办，插件脚本拿不到凭证本身。
enum MetaversePluginAuthType {
  /// 不需要授权
  none,

  /// 用户手动填写访问凭证（API Key 等），宿主存入系统安全存储
  token,
}

@immutable
class MetaversePluginAuthSpec {
  const MetaversePluginAuthSpec({
    this.type = MetaversePluginAuthType.none,
    this.label,
    this.helpUrl,
    this.header = 'Authorization',
    this.scheme = 'Bearer',
    this.hosts = const [],
  });

  final MetaversePluginAuthType type;

  /// 凭证输入框的名称，如 "API Key"。
  final String? label;

  /// 「如何获取」链接。
  final String? helpUrl;

  /// 凭证写入的请求头。
  final String header;

  /// 请求头值的前缀，空串表示直接写凭证。
  final String scheme;

  /// 允许附带凭证的域名，须是网络白名单的子集。
  final List<String> hosts;

  bool get required => type == MetaversePluginAuthType.token;
  bool get canAttachCredential => type != MetaversePluginAuthType.none;
}

@immutable
class MetaversePluginPageSpec {
  const MetaversePluginPageSpec({
    required this.id,
    required this.widget,
    required this.title,
    this.modal = false,
    this.scroll = true,
  });

  final String id;

  /// 界面库里的组件名。
  final String widget;
  final String title;
  final bool modal;
  final bool scroll;
}

/// 第三方插件清单，保持对旧版本插件的支持。
///
/// 清单是插件能力的唯一来源：能访问哪些域名、接管哪些链接、有哪些页面、
/// 怎么授权，全部在这里静态声明并在安装时展示给用户；脚本运行期不能扩权。
@immutable
class MetaversePluginManifest {
  const MetaversePluginManifest._({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.homepage,
    required this.icon,
    required this.uiPath,
    required this.scriptPath,
    required this.networkHosts,
    required this.publicImages,
    required this.reservedHosts,
    required this.identity,
    required this.auth,
    required this.runtimeSupported,
    required this.capabilities,
    required this.webLogin,
    required this.cardWidget,
    required this.pages,
    required this.links,
    required this.raw,
  });

  static const schemaVersion = 9;
  static const supportedApiVersions = {1, 2};
  int get apiVersion => raw['apiVersion'] as int? ?? 1;

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String? homepage;

  /// 宿主图标名，见界面组件库的图标表。
  final String? icon;

  /// 界面描述与脚本，相对清单地址的路径。
  final String uiPath;
  final String scriptPath;

  /// 网络白名单（域名模式）。脚本请求、界面图片都受它约束。
  final List<String> networkHosts;
  final bool publicImages;
  final List<String> reservedHosts;

  /// 是否允许读取当前用户名。
  final bool identity;

  final MetaversePluginAuthSpec auth;

  /// 旧协议仅保留管理和迁移入口，更新前不能运行。
  final bool runtimeSupported;
  final MetaversePluginCapabilities capabilities;

  /// 第一方网页登录地址。会话留在浏览器中，插件只可打开同源页面。
  final Uri? webLogin;

  Uri? webSessionPage(String path) {
    final login = webLogin;
    if (login == null ||
        path.length > 2048 ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains(r'\') ||
        path.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      return null;
    }
    final route = Uri.tryParse(path);
    if (route == null || route.hasAuthority || route.hasScheme) return null;
    final page = login.resolveUri(route);
    return page.origin == login.origin ? page : null;
  }

  /// 元宇宙页卡片对应的组件名；为空则只显示名称与入口。
  final String? cardWidget;
  final List<MetaversePluginPageSpec> pages;
  final List<MetaverseLinkRule> links;

  /// 原始 JSON，用于持久化后原样重新校验。
  final Map<String, dynamic> raw;

  /// 用户同意的运行权限；版本号、文案及 JS 资源不是授权。链接按匹配顺序比较。
  List<Object?> get _approval => [
    networkHosts.toSet(),
    identity,
    publicImages,
    webLogin,
    auth.type,
    auth.hosts.toSet(),
    auth.header,
    auth.scheme,
    runtimeSupported,
    capabilities.approval,
    links.map((r) => (r.host, r.path, r.page)).toList(),
  ];
  bool sameApprovalAs(MetaversePluginManifest other) =>
      const DeepCollectionEquality().equals(_approval, other._approval);

  MetaversePluginPageSpec? page(String id) {
    for (final page in pages) {
      if (page.id == id) return page;
    }
    return null;
  }

  /// 链接规则涉及的域名（去重），用于安装确认页展示。
  List<String> get linkHosts => {for (final link in links) link.host}.toList();

  static final _id = RegExp(r'^[a-z0-9]+([._-][a-z0-9]+)+$');
  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');
  static final _headerName = RegExp(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}$");

  /// 解析并校验清单。
  ///
  /// [reservedHosts] 是宿主站点域名：插件的网络白名单和链接规则都不能
  /// 落在站点域内——前者防止请求带上站点登录态，后者防止劫持站内链接。
  static MetaversePluginManifest parse(
    Object? json, {
    List<String> reservedHosts = const [],
    bool allowLegacyMetadata = false,
  }) {
    if (json is! Map<String, dynamic>) {
      throw const MetaverseManifestException('manifest', '必须是 JSON 对象');
    }
    final schema = json['schema'];
    if (schema is! int || schema < 1 || schema > schemaVersion) {
      throw MetaverseManifestException(
        'schema',
        '不支持的清单版本 $schema，当前支持 1 至 $schemaVersion',
      );
    }

    final id = _string(json, 'id', max: 64);
    if (id.length < 3 || !_id.hasMatch(id)) {
      throw const MetaverseManifestException(
        'id',
        '须为小写反向域名形式，如 com.example.points',
      );
    }
    final version = _string(json, 'version', max: 32);
    try {
      PluginVersion.parse(version);
    } on FormatException {
      throw const MetaverseManifestException('version', '须为 x.y.z 形式');
    }
    final apiVersion = json['apiVersion'] ?? 1;
    if ((schema >= 8 && json['apiVersion'] == null) ||
        !supportedApiVersions.contains(apiVersion) ||
        (apiVersion == 2 && schema < 9)) {
      throw const MetaverseManifestException('apiVersion', '不支持的脚本 API 版本');
    }
    if (apiVersion == 2 && json.containsKey('auth')) {
      throw const MetaverseManifestException('auth', 'API 2 使用 permissions 中的公共能力声明');
    }

    final legacy =
        allowLegacyMetadata &&
        json['auth'] is Map &&
        (json['auth'] as Map)['type'] == 'readSession';
    final permissions = _map(json, 'permissions');
    if (schema < 2 &&
        (json['webLogin'] != null || permissions['publicImages'] == true)) {
      throw const MetaverseManifestException('schema', '网站会话与公开图片需要 schema 2');
    }
    final networkHosts = _hosts(
      permissions['network'],
      'permissions.network',
      reservedHosts,
      max: 16,
    );
    final identity = permissions['identity'] == true;
    final MetaversePluginCapabilities capabilities;
    try {
      capabilities = MetaversePluginCapabilities.parse(
        permissions,
        networkHosts: networkHosts,
        forbiddenHeader: isForbiddenHeader,
      );
    } on FormatException catch (error) {
      throw MetaverseManifestException('permissions', error.message);
    }
    if (apiVersion == 1 && (capabilities.credentials.isNotEmpty ||
        capabilities.connectCallbacks.isNotEmpty || capabilities.payments.isNotEmpty)) {
      throw const MetaverseManifestException('apiVersion', '公共能力声明需要 API 2');
    }

    final pages = <MetaversePluginPageSpec>[];
    final rawPages = json['pages'];
    if (rawPages != null && rawPages is! List) {
      throw const MetaverseManifestException('pages', '必须是数组');
    }
    for (final (index, item) in ((rawPages as List?) ?? const []).indexed) {
      final field = 'pages[$index]';
      if (item is! Map<String, dynamic>) {
        throw MetaverseManifestException(field, '必须是对象');
      }
      final pageId = _string(item, 'id', max: 64, prefix: field);
      if (!_identifier.hasMatch(pageId) || pages.any((p) => p.id == pageId)) {
        throw MetaverseManifestException('$field.id', '须为唯一的标识符');
      }
      final presentation = item['presentation'] ?? 'page';
      if (schema < 2 && presentation == 'modal') {
        throw const MetaverseManifestException('schema', '弹层页面需要 schema 2');
      }
      if (presentation != 'page' && presentation != 'modal') {
        throw MetaverseManifestException(
          '$field.presentation',
          '须为 page 或 modal',
        );
      }
      if (item.containsKey('scroll') &&
          (schema < 6 || item['scroll'] is! bool)) {
        throw MetaverseManifestException('$field.scroll', '需要 schema 6 和布尔值');
      }
      pages.add(
        MetaversePluginPageSpec(
          id: pageId,
          widget: _widgetName(item, 'widget', field),
          title: _string(item, 'title', max: 40, prefix: field),
          modal: presentation == 'modal',
          scroll: item['scroll'] != false,
        ),
      );
    }
    if (pages.length > 16) {
      throw const MetaverseManifestException('pages', '最多 16 个页面');
    }

    final card = json['card'];
    String? cardWidget;
    if (card != null) {
      if (card is! Map<String, dynamic>) {
        throw const MetaverseManifestException('card', '必须是对象');
      }
      cardWidget = _widgetName(card, 'widget', 'card');
    }
    if (cardWidget == null && pages.isEmpty) {
      throw const MetaverseManifestException('card', '至少声明卡片或一个页面');
    }

    final links = <MetaverseLinkRule>[];
    final rawLinks = json['links'];
    if (rawLinks != null && rawLinks is! List) {
      throw const MetaverseManifestException('links', '必须是数组');
    }
    for (final (index, item) in ((rawLinks as List?) ?? const []).indexed) {
      final field = 'links[$index]';
      if (item is! Map<String, dynamic>) {
        throw MetaverseManifestException(field, '必须是对象');
      }
      final host = MetaverseHostPattern.normalize(
        _string(item, 'host', max: 253, prefix: field),
        reservedHosts: reservedHosts,
      );
      if (host == null) {
        throw MetaverseManifestException('$field.host', '域名不合法或属于站点自身');
      }
      final page = _string(item, 'page', max: 64, prefix: field);
      if (!pages.any((p) => p.id == page)) {
        throw MetaverseManifestException('$field.page', '未在 pages 中声明');
      }
      final rule = MetaverseLinkRule.parse(
        host: host,
        path: _string(item, 'path', max: 256, prefix: field),
        page: page,
      );
      if (rule == null) {
        throw MetaverseManifestException('$field.path', '路径模式不合法');
      }
      links.add(rule);
    }
    if (links.length > 32) {
      throw const MetaverseManifestException('links', '最多 32 条规则');
    }

    final webLoginText = _httpsUrl(json, 'webLogin');
    final webLogin = webLoginText == null ? null : Uri.parse(webLoginText);
    if (webLogin != null &&
        (webLogin.userInfo.isNotEmpty ||
            webLogin.authority.contains('@') ||
            webLogin.hasPort ||
            webLogin.hasFragment ||
            webLogin.host.contains('*') ||
            MetaverseHostPattern.normalize(
                  webLogin.host,
                  reservedHosts: reservedHosts,
                ) ==
                null)) {
      throw const MetaverseManifestException('webLogin', '须为服务的公开 HTTPS 登录页面');
    }
    return MetaversePluginManifest._(
      id: id,
      name: _string(json, 'name', max: 40),
      version: version,
      author: _string(json, 'author', max: 40),
      description: _optionalString(json, 'description', max: 200) ?? '',
      homepage: _httpsUrl(json, 'homepage'),
      icon: _optionalString(json, 'icon', max: 40),
      uiPath: _relativePath(json, 'ui'),
      scriptPath: _relativePath(json, 'script'),
      networkHosts: networkHosts,
      publicImages: permissions['publicImages'] == true,
      reservedHosts: List.unmodifiable(reservedHosts),
      identity: identity,
      auth: legacy
          ? const MetaversePluginAuthSpec()
          : _auth(json['auth'], networkHosts, reservedHosts),
      runtimeSupported: !legacy,
      capabilities: capabilities,
      webLogin: webLogin,
      cardWidget: cardWidget,
      pages: List.unmodifiable(pages),
      links: List.unmodifiable(links),
      raw: json,
    );
  }

  static MetaversePluginAuthSpec _auth(
    Object? value,
    List<String> networkHosts,
    List<String> reservedHosts,
  ) {
    if (value == null) return const MetaversePluginAuthSpec();
    if (value is! Map<String, dynamic>) {
      throw const MetaverseManifestException('auth', '必须是对象');
    }
    final type = value['type'];
    if (type == 'none') return const MetaversePluginAuthSpec();
    if (type != 'token') {
      throw MetaverseManifestException('auth.type', '授权协议已更新，请使用 API 2 公共能力');
    }
    final header = _optionalString(value, 'header', max: 64, prefix: 'auth');
    if (header != null &&
        (!_headerName.hasMatch(header) || isForbiddenHeader(header))) {
      throw const MetaverseManifestException('auth.header', '请求头名称不合法');
    }
    final hosts = _hosts(value['hosts'], 'auth.hosts', reservedHosts, max: 16);
    if (hosts.isEmpty) {
      throw const MetaverseManifestException('auth.hosts', '须声明凭证可发往的域名');
    }
    for (final host in hosts) {
      // 凭证只能发往白名单内的域名，通配范围也不能比白名单更宽。
      final covered = networkHosts.any(
        (allowed) =>
            allowed == host ||
            (allowed.startsWith('*.') &&
                !host.startsWith('*.') &&
                MetaverseHostPattern.matches(allowed, host)),
      );
      if (!covered) {
        throw MetaverseManifestException(
          'auth.hosts',
          '$host 不在 permissions.network 内',
        );
      }
    }
    return MetaversePluginAuthSpec(
      type: MetaversePluginAuthType.token,
      label: _optionalString(value, 'label', max: 40, prefix: 'auth'),
      helpUrl: _httpsUrl(value, 'helpUrl', prefix: 'auth'),
      header: header ?? 'Authorization',
      scheme:
          _optionalString(value, 'scheme', max: 32, prefix: 'auth') ?? 'Bearer',
      hosts: hosts,
    );
  }

  /// 插件不得自行设置的请求头：登录态、连接控制与浏览器保留前缀。
  static bool isForbiddenHeader(String name) {
    final lower = name.toLowerCase();
    return const {
          'cookie',
          'cookie2',
          'host',
          'content-length',
          'connection',
          'transfer-encoding',
          'upgrade',
          'te',
          'trailer',
          'keep-alive',
        }.contains(lower) ||
        lower.startsWith('proxy-') ||
        lower.startsWith('sec-');
  }

  static List<String> _hosts(
    Object? value,
    String field,
    List<String> reservedHosts, {
    required int max,
  }) {
    if (value == null) return const [];
    if (value is! List || value.length > max) {
      throw MetaverseManifestException(field, '必须是不超过 $max 项的数组');
    }
    final hosts = <String>{};
    for (final (index, item) in value.indexed) {
      final host = item is String
          ? MetaverseHostPattern.normalize(item, reservedHosts: reservedHosts)
          : null;
      if (host == null) {
        throw MetaverseManifestException('$field[$index]', '域名不合法、属于内网或属于站点自身');
      }
      hosts.add(host);
    }
    return List.unmodifiable(hosts);
  }

  static Map<String, dynamic> _map(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return const {};
    if (value is! Map<String, dynamic>) {
      throw MetaverseManifestException(key, '必须是对象');
    }
    return value;
  }

  static String _string(
    Map<String, dynamic> json,
    String key, {
    required int max,
    String? prefix,
  }) {
    final value = _optionalString(json, key, max: max, prefix: prefix);
    if (value == null) {
      throw MetaverseManifestException(_field(prefix, key), '必填');
    }
    return value;
  }

  static String? _optionalString(
    Map<String, dynamic> json,
    String key, {
    required int max,
    String? prefix,
  }) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty || value.length > max) {
      throw MetaverseManifestException(
        _field(prefix, key),
        '须为不超过 $max 个字符的非空字符串',
      );
    }
    return value.trim();
  }

  static String _widgetName(
    Map<String, dynamic> json,
    String key,
    String prefix,
  ) {
    final value = _string(json, key, max: 64, prefix: prefix);
    if (!_identifier.hasMatch(value)) {
      throw MetaverseManifestException('$prefix.$key', '组件名不合法');
    }
    return value;
  }

  static String _relativePath(Map<String, dynamic> json, String key) {
    final value = _string(json, key, max: 128);
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        value.startsWith('/') ||
        value.contains(r'\') ||
        uri.pathSegments.any((s) => s == '..' || s == '.' || s.isEmpty)) {
      throw MetaverseManifestException(key, '须为清单同目录下的相对路径');
    }
    return value;
  }

  static String? _httpsUrl(
    Map<String, dynamic> json,
    String key, {
    String? prefix,
  }) {
    final value = _optionalString(json, key, max: 512, prefix: prefix);
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw MetaverseManifestException(_field(prefix, key), '须为 https 链接');
    }
    return value;
  }

  static String _field(String? prefix, String key) =>
      prefix == null ? key : '$prefix.$key';
}
