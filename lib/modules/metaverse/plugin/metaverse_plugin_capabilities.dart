import 'dart:convert';

import '../core/metaverse_link_rule.dart';

enum MetaversePaymentProvider { linuxDoCredit }

enum MetaverseRequestMethod { get, head, post, put, patch, delete, options }

/// 凭证只用于安装时批准的目标、路径与 HTTP 方法。
class MetaverseCredentialScope {
  const MetaverseCredentialScope(this.origin, this.pathPrefix, this.methods);
  final Uri origin;
  final String pathPrefix;
  final Set<String> methods;

  bool allows(Uri uri, String method) {
    if (uri.origin != origin.origin ||
        uri.userInfo.isNotEmpty ||
        !methods.contains(method.toUpperCase())) {
      return false;
    }
    // 解码后的分隔符和点段不能绕过声明的路径范围。
    if (uri.pathSegments.any(
      (part) =>
          part == '.' ||
          part == '..' ||
          part.contains('/') ||
          part.contains(r'\'),
    )) {
      return false;
    }
    return pathPrefix == '/' ||
        uri.path == pathPrefix ||
        uri.path.startsWith('$pathPrefix/');
  }

  Map<String, Object> toJson() => {
    'origin': origin.origin,
    'pathPrefix': pathPrefix,
    'methods': methods.toList()..sort(),
  };
}

class MetaverseCredentialSpec {
  const MetaverseCredentialSpec({
    required this.name,
    required this.header,
    required this.scheme,
    required this.scopes,
    this.label,
  });
  final String name, header, scheme;
  final String? label;
  final List<MetaverseCredentialScope> scopes;

  bool allows(Uri uri, String method) =>
      scopes.any((scope) => scope.allows(uri, method));
  Map<String, Object> get approval => {
    'header': header.toLowerCase(),
    'scheme': scheme,
    'scopes': scopes.map((scope) => jsonEncode(scope.toJson())).toSet(),
  };
}

/// 通用宿主能力声明。服务端端点、订单字段和响应解析由插件定义。
class MetaversePluginCapabilities {
  const MetaversePluginCapabilities({
    this.credentials = const {},
    this.connectCallbacks = const [],
    this.payments = const {},
  });
  final Map<String, MetaverseCredentialSpec> credentials;
  final List<Uri> connectCallbacks;
  final Set<MetaversePaymentProvider> payments;

  Map<String, Object> get approval => {
    'credentials': credentials.map((key, spec) => MapEntry(key, spec.approval)),
    'connectCallbacks': connectCallbacks.map((uri) => uri.toString()).toSet(),
    'payments': payments,
  };

  bool allowsCallback(Uri uri) => connectCallbacks.any(
    (allowed) =>
        uri.scheme == allowed.scheme &&
        uri.userInfo.isEmpty &&
        uri.host == allowed.host &&
        uri.port == allowed.port &&
        uri.path == allowed.path,
  );

  static MetaversePluginCapabilities parse(
    Map<String, dynamic> permissions, {
    required List<String> networkHosts,
    required bool Function(String) forbiddenHeader,
  }) {
    Uri endpoint(Object? value) {
      final uri = value is String && value.length <= 4096
          ? Uri.tryParse(value)
          : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !MetaverseHostPattern.matchesAny(networkHosts, uri.host)) {
        throw const FormatException('能力地址须为已声明网络范围内的 HTTPS 地址');
      }
      return uri;
    }

    final rawCredentials = permissions['credentials'] ?? <String, Object?>{};
    if (rawCredentials is! Map || rawCredentials.length > 16) {
      throw const FormatException('credentials 须为至多 16 项的对象');
    }
    final credentials = <String, MetaverseCredentialSpec>{};
    for (final entry in rawCredentials.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,63}$').hasMatch(name) ||
          value is! Map) {
        throw const FormatException('凭证名称或声明无效');
      }
      final header = value['header'] ?? 'Authorization';
      final scheme = value['scheme'] ?? 'Bearer';
      final label = value['label'];
      if (header is! String ||
          !RegExp(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}$").hasMatch(header) ||
          forbiddenHeader(header) ||
          scheme is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{0,32}$').hasMatch(scheme) ||
          (label != null && (label is! String || label.length > 80))) {
        throw const FormatException('凭证请求头或名称无效');
      }
      final requests = value['requests'];
      if (requests is! List || requests.isEmpty || requests.length > 32) {
        throw const FormatException('凭证须声明请求范围');
      }
      final scopes = <MetaverseCredentialScope>[];
      for (final request in requests) {
        if (request is! Map) throw const FormatException('凭证请求范围无效');
        final origin = endpoint(request['origin']);
        final prefix = request['pathPrefix'] ?? '/';
        final methods = request['methods'];
        if ((origin.path.isNotEmpty && origin.path != '/') ||
            prefix is! String ||
            prefix.length > 512 ||
            !RegExp(r'^/(?:[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)?$')
                .hasMatch(prefix) ||
            methods is! List ||
            methods.isEmpty ||
            methods.any(
              (method) =>
                  method is! String ||
                  !MetaverseRequestMethod.values.any(
                    (value) => value.name.toUpperCase() == method,
                  ),
            )) {
          throw const FormatException('凭证 origin、路径前缀或请求方法无效');
        }
        scopes.add(
          MetaverseCredentialScope(
            origin,
            prefix,
            Set<String>.unmodifiable(methods.cast<String>()),
          ),
        );
      }
      credentials[name] = MetaverseCredentialSpec(
        name: name,
        header: header,
        scheme: scheme,
        label: label as String?,
        scopes: List.unmodifiable(scopes),
      );
    }
    final callbacks = permissions['connect'] ?? <Object>[];
    if (callbacks is! List || callbacks.length > 16) {
      throw const FormatException('connect 须声明至多 16 个回调地址');
    }
    final payments = permissions['payments'] ?? <Object>[];
    if (payments is! List) throw const FormatException('payments 须为数组');
    final providers = <MetaversePaymentProvider>{};
    for (final payment in payments) {
      final matches = MetaversePaymentProvider.values.where(
        (value) => value.name == payment,
      );
      if (matches.isEmpty) throw const FormatException('支付提供方不可用');
      providers.add(matches.single);
    }
    return MetaversePluginCapabilities(
      credentials: Map.unmodifiable(credentials),
      connectCallbacks: List.unmodifiable(callbacks.map(endpoint)),
      payments: Set.unmodifiable(providers),
    );
  }
}
