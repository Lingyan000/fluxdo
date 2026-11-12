import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:mime/mime.dart';

import '../../../constants.dart';
import '../../../services/network/core/net_core_http_adapter.dart';
import '../../../services/network/android_route_snapshot.dart';
import '../../../services/network_logger.dart';
import '../core/metaverse_link_rule.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_capabilities.dart';
import 'metaverse_checkout_types.dart';
import 'metaverse_service_session.dart';
import 'metaverse_socket_connection.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

typedef MetaverseAddressLookup = Future<List<InternetAddress>> Function(
  String host,
);

/// 同一次解析的筛选结果，不保留被拦截的具体地址。
typedef _PluginTarget = ({
  List<InternetAddress> pins,
  int resolvedV4,
  int filteredV4,
  int fakeIpCount,
  String? directError,
});

/// 已校验的候选地址均为 IPv6，且匿名读取在建连阶段超时。
class MetaverseIpv6ReadTimeout extends MetaversePluginCallException {
  const MetaverseIpv6ReadTimeout(this.host)
    : super('网络请求失败: connectionTimeout');
  final String host;
}

/// 第三方插件的出站网络。
///
/// 刻意不复用 `DiscourseDio`：那条链路会带站点 Cookie、CSRF Token，并在
/// 兼容模式下借用 WebView 的登录态。插件请求必须是没有任何环境凭证的
/// 干净请求，所以这里用一个独立、无拦截器、无 Cookie 的客户端。
///
/// 直连使用宿主筛选的地址，保留 Fake-IP 交给系统路由。显式代理按原域名建隧道。
class MetaversePluginNetwork {
  MetaversePluginNetwork({
    this._dio,
    Dio? coreDio,
    MetaverseAddressLookup? lookup,
    this.useNetworkCore,
    this.diagnosticNetwork,
  }) : _coreDio =
           coreDio ??
           (useNetworkCore == null
               ? null
               : (Dio(_options())
                   ..httpClientAdapter = NetCoreHttpAdapter(
                     pluginRequests: true,
                   ))),
       _lookup = lookup ?? InternetAddress.lookup;

  static const maxRequestBody = 256 * 1024;
  static const maxResponseBody = 1024 * 1024;
  static const maxImageBytes = 16 * 1024 * 1024;

  static BaseOptions _options() => BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
    // 不自动跟随跳转：跳转目标也要过白名单，由插件拿到 Location 后自己再请求。
    followRedirects: false,
    validateStatus: (_) => true,
  );

  static Dio _createDio(List<InternetAddress> addresses) =>
      Dio(_options())
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            return HttpClient()
              ..findProxy = ((_) => 'DIRECT')
              ..connectionFactory = (uri, _, _) =>
                  startMetaverseConnection(uri, addresses);
          },
        );

  final Dio? _dio;
  final Dio? _coreDio;
  final _directClients = <Dio>{};
  final bool Function()? useNetworkCore;
  final String Function()? diagnosticNetwork;
  final MetaverseAddressLookup _lookup;

  void dispose() {
    _dio?.close(force: true);
    _coreDio?.close(force: true);
    for (final client in _directClients) {
      client.close(force: true);
    }
    _directClients.clear();
  }

  /// 图片请求不携带凭证，不跟随跳转，返回值仅交给宿主图片组件。
  Future<Uint8List> loadImage(MetaversePluginManifest manifest, Uri uri) async {
    if (MetaverseHostPattern.normalize(
          uri.host,
          reservedHosts: manifest.reservedHosts,
        ) ==
        null) {
      throw const MetaversePluginCallException('图片域名不合法');
    }
    final target = await _checkTarget(
      uri,
      manifest.publicImages ? null : manifest.networkHosts,
    );
    final response = await _send(
      uri,
      target: target,
      method: 'GET',
      headers: {
        'User-Agent': await AppConstants.getUserAgent(),
        'Accept': 'image/*',
      },
      body: null,
      maxBytes: maxImageBytes,
    );
    final contentType = (response.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    // 部分图床返回通用二进制类型，按文件头识别，避免把错误页当成图片。
    final imageType = switch (contentType) {
      '' || 'application/octet-stream' => lookupMimeType(
        '',
        headerBytes: response.bytes,
      ),
      _ => contentType,
    };
    if (response.status != 200 || imageType?.startsWith('image/') != true) {
      throw const MetaversePluginCallException('图片不可用');
    }
    return response.bytes;
  }

  /// 执行插件脚本发起的请求，返回交给脚本的响应对象。
  ///
  /// [authToken] 非空表示脚本要求附带凭证；是否允许发往该域名在这里判断。
  Future<Map<String, Object?>> fetch(
    MetaversePluginManifest manifest, {
    required Map<String, Object?> request,
    required String? authToken,
    void Function()? checkActive,
  }) async {
    final rawUrl = request['url'];
    final uri = rawUrl is String ? Uri.tryParse(rawUrl) : null;
    if (uri == null) throw const MetaversePluginCallException('请求地址不合法');
    final target = await _checkTarget(uri, manifest.networkHosts);

    final method = '${request['method'] ?? 'GET'}'.toUpperCase();
    final credentialName = request['credential'];
    final credential = manifest.capabilities.credentials[credentialName];
    if (credentialName != null && credential == null) {
      throw const MetaversePluginCallException('credential_not_declared');
    }
    if (!MetaverseRequestMethod.values.any(
      (value) => value.name.toUpperCase() == method,
    )) {
      throw MetaversePluginCallException('不支持的请求方法 $method');
    }

    final headers = <String, String>{};
    final rawHeaders = request['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final name = '${entry.key}';
        final value = '${entry.value}';
        if (MetaversePluginManifest.isForbiddenHeader(name) ||
            name.length > 64 ||
            value.length > 4096 ||
            value.contains('\n') ||
            value.contains('\r')) {
          throw MetaversePluginCallException('不允许的请求头 $name');
        }
        headers[name] = value;
      }
    }

    if (credential != null) {
      if (!credential.allows(uri, method)) {
        throw const MetaversePluginCallException('credential_scope_denied');
      }
      if (authToken == null || authToken.isEmpty) {
        throw const MetaversePluginCallException('credential_required');
      }
      headers.removeWhere(
        (name, _) => name.toLowerCase() == credential.header.toLowerCase(),
      );
      headers[credential.header] = credential.scheme.isEmpty
          ? authToken
          : '${credential.scheme} $authToken';
    } else if (request['auth'] == true) {
      final auth = manifest.auth;
      if (!auth.canAttachCredential) {
        throw const MetaversePluginCallException('清单未声明授权方式');
      }
      if (auth.type == MetaversePluginAuthType.readSession &&
          (method != 'GET' || request['body'] != null || headers.isNotEmpty)) {
        throw const MetaversePluginCallException('此服务会话只支持无自定义请求头、无请求体的 GET');
      }
      if (!MetaverseHostPattern.matchesAny(auth.hosts, uri.host)) {
        throw MetaversePluginCallException('凭证不允许发往 ${uri.host}');
      }
      if (authToken == null || authToken.isEmpty) {
        throw const MetaversePluginCallException('auth_required');
      }
      headers.removeWhere(
        (name, _) => name.toLowerCase() == auth.header.toLowerCase(),
      );
      headers[auth.header] = auth.scheme.isEmpty
          ? authToken
          : '${auth.scheme} $authToken';
    }

    final body = request['body'];
    if (body != null && body is! String) {
      throw const MetaversePluginCallException('请求体须为字符串');
    }
    if (body is String && utf8.encode(body).length > maxRequestBody) {
      throw const MetaversePluginCallException('请求体过大');
    }

    checkActive?.call();
    final response = await _send(
      uri,
      target: target,
      method: method,
      headers: headers,
      body: body as String?,
      maxBytes: maxResponseBody,
    );
    checkActive?.call();
    return {
      'status': response.status,
      'headers': response.headers,
      'body': utf8.decode(response.bytes, allowMalformed: true),
    };
  }

  /// 只向清单与宿主会话都授权的精确端点发送 JSON 查询，不接受脚本传入 URL 或请求头。
  Future<Map<String, Object?>> query(
    MetaversePluginManifest manifest,
    String name,
    Map<String, Object?> arguments,
    MetaverseServiceSession? session,
  ) async {
    final endpoint = manifest.auth.queries[name];
    if (manifest.auth.type != MetaversePluginAuthType.readSession ||
        endpoint == null ||
        session == null ||
        !session.queryUrls.contains(endpoint)) {
      throw const MetaversePluginCallException('query_not_granted');
    }
    final body = jsonEncode(arguments);
    if (utf8.encode(body).length > maxRequestBody) {
      throw const MetaversePluginCallException('请求体过大');
    }
    final uri = Uri.parse(endpoint);
    final target = await _checkTarget(uri, manifest.networkHosts);
    final response = await _send(
      uri,
      target: target,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${session.token}',
      },
      body: body,
      maxBytes: maxResponseBody,
    );
    return {
      'status': response.status,
      'body': utf8.decode(response.bytes, allowMalformed: true),
    };
  }

  /// 订单协议不接受自由请求体、目标 URL 或来自脚本的提交号。
  Future<Map<String, Object?>> orderRequest(
    MetaversePluginManifest manifest,
    MetaverseServiceSession session,
    String submissionToken, {
    MetaverseOrderIntent? create,
    required Future<void> Function() checkSession,
  }) async {
    final endpoints = manifest.auth.checkout;
    if (endpoints == null ||
        session.checkout?.endpoints != endpoints ||
        !RegExp(r'^ord_[0-9a-f]{32}$').hasMatch(submissionToken)) {
      throw const MetaversePluginCallException('checkout_not_granted');
    }
    final uri = Uri.parse(
      create == null
          ? '${endpoints.lookup}/$submissionToken'
          : endpoints.create,
    );
    final target = await _checkTarget(uri, manifest.networkHosts);
    await checkSession();
    final response = await _send(
      uri,
      target: target,
      method: create == null ? 'GET' : 'POST',
      headers: {
        'Authorization': 'Bearer ${session.token}',
        if (create != null) 'Content-Type': 'application/json',
      },
      body: create == null
          ? null
          : jsonEncode({
              ...create.toJson(),
              'submissionToken': submissionToken,
            }),
      maxBytes: maxResponseBody,
    );
    return {
      'status': response.status,
      'body': utf8.decode(response.bytes, allowMalformed: true),
    };
  }

  /// 读取、刷新或取消同一服务的买家订单，凭证留在宿主内。
  Future<Map<String, Object?>> paymentOrderRequest(
    MetaversePluginManifest manifest,
    MetaverseServiceSession session,
    String orderNo,
    String action, {
    required Future<void> Function() checkSession,
  }) async {
    if (manifest.auth.payment != 'linuxDoCredit' ||
        session.checkout?.endpoints != manifest.auth.checkout ||
        !MetaverseOrderIntent.validId(orderNo)) {
      throw const MetaversePluginCallException('payment_not_granted');
    }
    final (suffix, method) = switch (action) {
      'details' => ('?role=buyer', 'GET'),
      'payment' => ('/payment-url', 'GET'),
      'refresh' => ('/refresh', 'POST'),
      'cancel' => ('/cancel', 'POST'),
      _ => throw const MetaversePluginCallException('payment_invalid_action'),
    };
    final uri = Uri.parse('${manifest.auth.checkout!.create}/$orderNo$suffix');
    final target = await _checkTarget(uri, manifest.networkHosts);
    await checkSession();
    final response = await _send(
      uri,
      target: target,
      method: method,
      body: null,
      headers: {'Authorization': 'Bearer ${session.token}'},
      maxBytes: maxResponseBody,
    );
    await checkSession();
    return {'status': response.status, 'body': utf8.decode(response.bytes)};
  }

  /// 下载插件包里的一个文件（清单、界面描述、脚本）。
  Future<String> download(Uri uri, {required int maxBytes}) async {
    final target = await _checkTarget(uri, null);
    final response = await _send(
      uri,
      target: target,
      method: 'GET',
      headers: const {},
      body: null,
      maxBytes: maxBytes,
    );
    if (response.status != 200) {
      throw MetaversePluginCallException('下载失败（HTTP ${response.status}）');
    }
    return utf8.decode(response.bytes);
  }

  /// 市场索引与发布附件使用匿名下载，每一次重定向重新检查网络目标。
  Future<({int status, Map<String, String> headers, Uint8List bytes})> downloadResource(
    Uri uri, {
    required int maxBytes,
    String? etag,
  }) async {
    var current = uri;
    for (var hop = 0; hop < 6; hop++) {
      final target = await _checkTarget(current, null);
      final response = await _send(
        current,
        target: target,
        method: 'GET',
        headers: {
          'User-Agent': await AppConstants.getUserAgent(),
          if (etag != null && current == uri) 'If-None-Match': etag,
        },
        body: null,
        maxBytes: maxBytes,
      );
      if (response.status >= 300 && response.status < 400 && response.status != 304) {
        final location = response.headers['location'];
        if (location == null) throw const MetaversePluginCallException('下载重定向缺少地址');
        current = current.resolve(location);
        continue;
      }
      return response;
    }
    throw const MetaversePluginCallException('下载重定向次数过多');
  }

  /// 校验目标地址；[allowedHosts] 为 null 时只做协议与内网检查。
  Future<_PluginTarget> _checkTarget(
    Uri uri,
    List<String>? allowedHosts,
  ) async {
    if (uri.scheme != 'https' ||
        MetaverseHostPattern.normalize(uri.host) == null ||
        uri.host.contains('*') ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw const MetaversePluginCallException('只允许标准端口的 https 地址');
    }
    if (allowedHosts != null &&
        !MetaverseHostPattern.matchesAny(allowedHosts, uri.host)) {
      throw MetaversePluginCallException(
        '${uri.host} 不在清单 permissions.network 内',
      );
    }
    // 本次直连使用同一份解析快照；代理可以按自己的 DNS 与路由处理域名。
    return _publicAddresses(uri.host, _lookup);
  }

  static Future<_PluginTarget> _publicAddresses(
    String host,
    MetaverseAddressLookup lookup,
  ) async {
    List<InternetAddress> addresses = const [];
    String? directError;
    try {
      addresses = await lookup(host);
    } catch (_) {
      directError = '无法解析 $host';
    }
    if (addresses.isEmpty) directError = '无法解析 $host';
    final pins = <InternetAddress>[];
    var resolvedV4 = 0;
    var filteredV4 = 0;
    for (final address in addresses.toSet()) {
      final v4 = address.type == InternetAddressType.IPv4;
      if (v4) resolvedV4++;
      final fakeIp = isFakeIpAddress(address);
      if (isPrivateAddress(address) && !fakeIp) {
        if (v4) filteredV4++;
      } else {
        pins.add(address);
      }
    }
    final candidates = interleaveMetaverseAddresses(pins).take(16).toList();
    return (
      pins: candidates,
      resolvedV4: resolvedV4,
      filteredV4: filteredV4,
      fakeIpCount: candidates.where(isFakeIpAddress).length,
      directError: pins.isEmpty ? directError ?? '$host 只解析到内网或保留地址' : null,
    );
  }

  /// 常用 Fake-IP 地址池，仅作为已授权域名的 DNS 传输地址。
  /// URL 中的 IP 字面量仍由域名校验拒绝，TLS 使用原始域名。
  static bool isFakeIpAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) return b[0] == 198 && (b[1] == 18 || b[1] == 19);
    if (b.sublist(0, 10).every((byte) => byte == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff) {
      return b[12] == 198 && (b[13] == 18 || b[13] == 19);
    }
    return b[0] == 0x20 &&
        b[1] == 1 &&
        b[2] == 0 &&
        b[3] == 2 &&
        b[4] == 0 &&
        b[5] == 0;
  }

  /// 是否为本机、内网或其它不应由第三方代码访问的地址。
  static bool isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    final bytes = address.rawAddress;
    if (bytes.length == 4) return _isPrivateV4(bytes);
    // IPv4 映射地址 ::ffff:a.b.c.d
    if (bytes.sublist(0, 10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return _isPrivateV4(bytes.sublist(12));
    }
    // 只接收全球单播；排除过渡隧道和文档网段。
    return isFakeIpAddress(address) ||
        (bytes[0] & 0xe0) != 0x20 ||
        (bytes[0] == 0x20 && bytes[1] == 0x02) ||
        (bytes[0] == 0x20 &&
            bytes[1] == 0x01 &&
            ((bytes[2] == 0 && bytes[3] == 0) ||
                (bytes[2] == 0x0d && bytes[3] == 0xb8)));
  }

  static bool _isPrivateV4(List<int> b) =>
      b[0] == 0 ||
      b[0] == 10 ||
      b[0] == 127 ||
      (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
      (b[0] == 169 && b[1] == 254) ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
      (b[0] == 198 && (b[1] == 18 || b[1] == 19)) ||
      (b[0] == 198 && b[1] == 51 && b[2] == 100) ||
      (b[0] == 203 && b[1] == 0 && b[2] == 113) ||
      b[0] >= 224;

  Future<({int status, Map<String, String> headers, Uint8List bytes})> _send(
    Uri uri, {
    required _PluginTarget target,
    required String method,
    required Map<String, String> headers,
    required String? body,
    required int maxBytes,
  }) async {
    final pins = target.pins;
    final core = useNetworkCore?.call() == true;
    if (!core && target.directError != null) {
      throw MetaversePluginCallException(target.directError!);
    }
    final client = core ? _coreDio! : _dio ?? _createDio(pins);
    final ownsClient = !core && _dio == null;
    if (ownsClient) _directClients.add(client);
    try {
      final cancel = CancelToken();
      final Response<ResponseBody> response;
      final route = diagnosticNetwork?.call();
      try {
        response = await client.requestUri<ResponseBody>(
          uri,
          data: body,
          cancelToken: cancel,
          options: Options(
            method: method,
            extra: {'pinnedAddresses': pins.map((a) => a.address).toList()},
            headers: headers,
            responseType: ResponseType.stream,
          ),
        );
      } on DioException catch (error) {
        if (route != null) {
          final v4 = pins
              .where((a) => a.type == InternetAddressType.IPv4)
              .length;
          final destinations =
              core && error.type == DioExceptionType.connectionTimeout
              ? ' resolvedV4=${target.resolvedV4} filteredV4=${target.filteredV4} candidates=${pins.map((a) => a.address).join(',')} ${await androidRouteSnapshot(pins)}'
                    .trimRight()
              : '';
          NetworkLogger.log(
            '[插件网络] ${uri.host} ${error.type.name} $route '
            'transport=${core ? 'core' : 'io'} IPv4=$v4 IPv6=${pins.length - v4} fakeIp=${target.fakeIpCount}$destinations',
            level: 'warning',
          );
        }
        if (error.error case final MetaversePluginCallException denied) {
          throw denied;
        }
        if (method == 'GET' &&
            body == null &&
            headers.isEmpty &&
            error.type == DioExceptionType.connectionTimeout &&
            pins.isNotEmpty &&
            pins.every((a) => a.type == InternetAddressType.IPv6)) {
          throw MetaverseIpv6ReadTimeout(uri.host);
        }
        throw MetaversePluginCallException('网络请求失败: ${error.type.name}');
      }

      final builder = BytesBuilder(copy: false);
      try {
        await for (final chunk in response.data!.stream) {
          builder.add(chunk);
          if (builder.length > maxBytes) {
            cancel.cancel();
            throw const MetaversePluginCallException('响应过大');
          }
        }
      } on MetaversePluginCallException {
        rethrow;
      } catch (_) {
        throw const MetaversePluginCallException('读取响应失败');
      }
      return (
        status: response.statusCode ?? 0,
        headers: {
          for (final entry in response.headers.map.entries)
            // 不把 Set-Cookie 交给脚本：宿主不替插件维护 Cookie 会话。
            if (entry.key.toLowerCase() != 'set-cookie')
              entry.key.toLowerCase(): entry.value.join(', '),
        },
        bytes: builder.takeBytes(),
      );
    } finally {
      if (ownsClient) {
        _directClients.remove(client);
        client.close(force: true);
      }
    }
  }
}
