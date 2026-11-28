import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:mime/mime.dart';

import '../../../constants.dart';
import '../../../services/plugin_image_cache.dart';
import '../../../services/network/core/net_core_http_adapter.dart';
import '../../../services/network/android_route_snapshot.dart';
import '../../../services/network_logger.dart';
import '../../../utils/svg_utils.dart';
import '../core/metaverse_link_rule.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_capabilities.dart';
import 'metaverse_plugin_files.dart';
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
  static const maxImageBytes = PluginImageCache.maxImageBytes;

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

  /// 图片匿名下载，每一跳重新检查权限、宿主保留域名与公网地址。
  Future<Uint8List> loadImage(MetaversePluginManifest manifest, Uri uri, {
    bool forumAvatar = false, bool allowPublicImages = true, void Function()? checkActive,
    PluginImageCache? cache, String? cacheSource, int? account, Object? runtime, bool reload = false,
  }) async {
    final source = _imageUri(uri).removeFragment();
    final allowExternal = manifest.publicImages && allowPublicImages;
    checkActive?.call();
    _validateTarget(source, allowExternal || forumAvatar ? null : manifest.networkHosts,
      image: true, reservedHosts: forumAvatar ? const [] : manifest.reservedHosts);

    Future<PluginImageResponse> download() async {
      final response = await downloadResource(source, maxBytes: maxImageBytes, imageManifest: manifest,
        forumAvatar: forumAvatar, allowPublicImages: allowPublicImages, checkActive: checkActive);
      final contentType = (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      // 部分图床标错 MIME，先认文件头；只能靠声明识别的内容仍可尝试显示，但不缓存。
      final detected = SvgUtils.isSvgBytes(response.bytes) ? 'image/svg+xml' : lookupMimeType('', headerBytes: response.bytes);
      if (response.status != 200 || response.bytes.isEmpty || !(detected ?? contentType).startsWith('image/')) {
        throw const MetaversePluginCallException('图片不可用');
      }
      return (bytes: response.bytes, cacheHeaders: !response.redirected && detected != null
        ? response.headers : null);
    }

    if (cache == null || cacheSource == null) return (await download()).bytes;
    final bytes = await cache.load(pluginId: manifest.id,
      variant: jsonEncode([cacheSource, account, source.toString(), manifest.homepage, allowExternal, forumAvatar]),
      runtime: runtime ?? this, reusable: !source.hasQuery, reload: reload, download: download, checkActive: checkActive);
    checkActive?.call();
    return bytes;
  }

  static Uri _imageUri(Uri uri) => uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri;

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
    final headers = _requestHeaders(manifest, uri, method, request, authToken);

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

  /// 附件仍使用插件的匿名出口，凭证只能附加到清单批准的目标。
  Future<Map<String, Object?>> uploadFile(MetaversePluginManifest manifest, {
    required Map<String, Object?> request, required MetaversePickedFile file,
    required String? authToken, required CancelToken cancel,
    required void Function() checkActive, required ProgressCallback onProgress,
  }) async {
    final uri = Uri.tryParse('${request['url']}');
    if (uri == null) throw const MetaversePluginCallException('file_upload_url_invalid');
    final method = '${request['method'] ?? 'POST'}'.toUpperCase();
    if (!{'POST','PUT','PATCH'}.contains(method)) throw const MetaversePluginCallException('file_upload_method_invalid');
    final target = await _checkTarget(uri, manifest.networkHosts);
    final headers = _requestHeaders(manifest, uri, method, request, authToken);
    headers.removeWhere((key, _) => key.toLowerCase() == 'content-type');
    final field = request['field'] ?? 'file';
    final fields = request['fields'] ?? <String, Object?>{};
    if (field is! String || !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(field) ||
        fields is! Map<String, Object?> || fields.length > 32 || fields.containsKey(field) ||
        utf8.encode(jsonEncode(fields)).length > 16384 ||
        fields.keys.any((key) => !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(key))) {
      throw const MetaversePluginCallException('file_upload_fields_invalid');
    }
    final Object body;
    switch (request['encoding']) {
      case 'base64':
        headers['Content-Type'] = 'application/json';
        body = jsonEncode({...fields, field: base64Encode(file.bytes)});
      case 'multipart':
        if (fields.values.any((value) => value is! String)) throw const MetaversePluginCallException('file_upload_fields_invalid');
        body = FormData.fromMap({...fields, field: MultipartFile.fromBytes(file.bytes, filename: file.name,
          contentType: DioMediaType.parse(lookupMimeType(file.name, headerBytes: file.bytes) ?? 'application/octet-stream'))});
      default: throw const MetaversePluginCallException('file_upload_encoding_invalid');
    }
    checkActive();
    final response = await _send(uri, target: target, method: method, headers: headers, body: body,
      maxBytes: maxResponseBody, cancelToken: cancel, transferTimeout: const Duration(seconds:60), onSendProgress: (sent, total) {
        try { checkActive(); onProgress(sent, total); } catch (_) { cancel.cancel(); }
      });
    checkActive();
    return {'status': response.status, 'headers': response.headers, 'body': utf8.decode(response.bytes, allowMalformed: true)};
  }

  /// 私密预览不进入共享图片缓存，不跟随重定向，也不把字节返回脚本。
  Future<Uint8List> privateImage(MetaversePluginManifest manifest, {
    required Map<String, Object?> request, required String? authToken,
    required CancelToken cancel, required void Function() checkActive,
  }) async {
    final uri = Uri.tryParse('${request['url']}');
    if (uri == null) throw const MetaversePluginCallException('file_preview_url_invalid');
    final target = await _checkTarget(uri, manifest.networkHosts);
    final headers = _requestHeaders(manifest, uri, 'GET', request, authToken);
    checkActive();
    final response = await _send(uri, target: target, method: 'GET', headers: headers, body: null,
      maxBytes: maxImageBytes, cancelToken: cancel);
    checkActive();
    validatePrivateImage(response.bytes, status: response.status);
    return response.bytes;
  }

  static void validatePrivateImage(Uint8List bytes, {int status = 200}) {
    final type = lookupMimeType('', headerBytes: bytes);
    if (status != 200 || bytes.length > maxImageBytes || !{'image/png','image/jpeg','image/webp','image/gif'}.contains(type)) {
      throw const MetaversePluginCallException('file_preview_not_image');
    }
  }

  Map<String, String> _requestHeaders(MetaversePluginManifest manifest, Uri uri,
      String method, Map<String, Object?> request, String? authToken) {
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

    return headers;
  }

  /// 长连接复用普通请求的出口、TLS 与凭证范围，内容只按事件逐帧交付。
  Future<void> consumeEvents(MetaversePluginManifest manifest, {
    required Map<String, Object?> request,
    required String? authToken,
    required CancelToken cancel,
    required void Function() checkActive,
    required Future<void> Function() onOpen,
    required Future<void> Function(PluginServerEvent) onEvent,
    required void Function(int) onRetry,
    String lastEventId = '',
  }) async {
    final uri = Uri.parse(request['url'] as String);
    final target = await _checkTarget(uri, manifest.networkHosts).timeout(const Duration(seconds: 15));
    final headers = _requestHeaders(manifest, uri, 'GET', request, authToken);
    headers.removeWhere((key, _) => {'accept', 'cache-control', 'last-event-id'}.contains(key.toLowerCase()));
    headers['Accept'] = 'text/event-stream';
    headers['Cache-Control'] = 'no-cache';
    if (lastEventId.isNotEmpty && !lastEventId.contains(RegExp(r'[\x00-\x1f\x7f]'))) headers['Last-Event-ID'] = lastEventId;
    checkActive();
    if (cancel.isCancelled) return;
    await _send(uri, target: target, method: 'GET', headers: headers, body: null,
      maxBytes: 0, cancelToken: cancel,
      consume: (response) async {
        checkActive();
        final status = response.statusCode ?? 0;
        if (status != 200) {
          final seconds = int.tryParse(response.headers.value('retry-after') ?? '');
          throw MetaverseStreamException('stream_http_$status', status: status,
            retryAfter: seconds == null ? null : Duration(seconds: seconds.clamp(1, 3600)),
            retryable: status == 429 || status >= 500);
        }
        if (response.headers.value('content-type')?.split(';').first.trim().toLowerCase() != 'text/event-stream') {
          throw const MetaverseStreamException('stream_invalid_content_type');
        }
        await onOpen();
        var bytes = 0, events = 0;
        final window = Stopwatch()..start();
        void budget({int size = 0, bool event = false}) {
          checkActive();
          if (window.elapsed >= const Duration(seconds: 10)) {
            bytes = 0; events = 0; window.reset();
          }
          bytes += size;
          if (event) events++;
          if (bytes > 1024 * 1024 || events > 300) {
            throw const MetaverseStreamException('stream_rate_limited');
          }
        }
        try {
          final chunks = response.data!.stream.timeout(const Duration(seconds: 75)).map((chunk) {
            budget(size: chunk.length);
            return chunk;
          });
          await for (final event in decodePluginEventStream(chunks, onRetry: onRetry, lastEventId: lastEventId)) {
            budget(event: true);
            await onEvent(event);
          }
        } on FormatException {
          throw const MetaverseStreamException('stream_invalid_frame');
        }
      });
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

  /// 图片、市场索引与发布附件匿名下载，每一次重定向重新检查网络目标。
  Future<({int status, Map<String, String> headers, Uint8List bytes, bool redirected})> downloadResource(
    Uri uri, {
    required int maxBytes,
    String? etag,
    MetaversePluginManifest? imageManifest,
    bool forumAvatar = false,
    bool allowPublicImages = true,
    void Function()? checkActive,
  }) async {
    var current = uri;
    final homepage = Uri.tryParse(imageManifest?.homepage ?? '');
    for (var hop = 0; hop < 6; hop++) {
      checkActive?.call();
      // 与 HTTPS 网页的图片升级行为一致，每次连接仍要求 TLS 校验。
      if (imageManifest != null) current = _imageUri(current);
      final target = await _checkTarget(
        current,
        imageManifest != null && !(forumAvatar && hop == 0) && !(imageManifest.publicImages && allowPublicImages)
            ? imageManifest.networkHosts : null,
        image: imageManifest != null,
        reservedHosts: forumAvatar && hop == 0 ? const [] : imageManifest?.reservedHosts ?? const [],
      );
      final agent = await AppConstants.getUserAgent();
      checkActive?.call();
      final response = await _send(
        current,
        target: target,
        method: 'GET',
        headers: {
          'User-Agent': agent,
          if (imageManifest != null) 'Accept': 'image/*',
          // 与网站跨域图片请求一致，只发送清单公开主页的 origin。
          if (imageManifest != null &&
              homepage?.scheme == 'https' &&
              homepage!.host.isNotEmpty &&
              homepage.userInfo.isEmpty)
            'Referer': '${homepage.origin}/',
          if (etag != null && current == uri) 'If-None-Match': etag,
        },
        body: null,
        maxBytes: maxBytes,
      );
      checkActive?.call();
      if (response.status >= 300 && response.status < 400 && response.status != 304) {
        final location = response.headers['location'];
        if (location == null) throw const MetaversePluginCallException('下载重定向缺少地址');
        current = current.resolve(location);
        continue;
      }
      return (status: response.status, headers: response.headers, bytes: response.bytes, redirected: hop != 0);
    }
    throw const MetaversePluginCallException('下载重定向次数过多');
  }

  /// 校验目标地址；[allowedHosts] 为 null 时只做协议与内网检查。
  Future<_PluginTarget> _checkTarget(
    Uri uri,
    List<String>? allowedHosts, {
    bool image = false,
    List<String> reservedHosts = const [],
  }) async {
    _validateTarget(uri, allowedHosts, image: image, reservedHosts: reservedHosts);
    // 本次直连使用同一份解析快照；代理可以按自己的 DNS 与路由处理域名。
    return _publicAddresses(uri.host, _lookup);
  }

  static void _validateTarget(Uri uri, List<String>? allowedHosts, {
    required bool image, required List<String> reservedHosts,
  }) {
    if (uri.scheme != 'https' ||
        MetaverseHostPattern.normalize(
              uri.host,
              reservedHosts: reservedHosts,
              resourceHost: image,
            ) ==
            null ||
        uri.host.contains('*') ||
        uri.userInfo.isNotEmpty ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (!image && uri.hasPort && uri.port != 443)) {
      throw MetaversePluginCallException(
        image ? '图片地址不合法' : '只允许标准端口的 https 地址',
      );
    }
    if (allowedHosts != null &&
        !MetaverseHostPattern.matchesAny(allowedHosts, uri.host)) {
      throw MetaversePluginCallException(
        '${uri.host} 不在清单 permissions.network 内',
      );
    }
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
    required Object? body,
    required int maxBytes,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    Duration? transferTimeout,
    Future<void> Function(Response<ResponseBody>)? consume,
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
      final cancel = cancelToken ?? CancelToken();
      final Response<ResponseBody> response;
      final route = diagnosticNetwork?.call();
      try {
        response = await client.requestUri<ResponseBody>(
          uri,
          data: body,
          cancelToken: cancel,
          onSendProgress: onSendProgress,
          options: Options(
            method: method,
            followRedirects: false,
            validateStatus: (_) => true,
            extra: {'pinnedAddresses': pins.map((a) => a.address).toList()},
            headers: {
              if (!headers.keys.any((name) => name.toLowerCase() == 'user-agent'))
                'User-Agent': AppConstants.userAgent,
              ...headers,
            },
            responseType: ResponseType.stream,
            sendTimeout: transferTimeout,
            receiveTimeout: consume == null ? transferTimeout : const Duration(seconds: 75),
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

      if (consume != null) {
        try { await consume(response); }
        finally { cancel.cancel(); }
        return (status: response.statusCode ?? 0, headers: <String, String>{}, bytes: Uint8List(0));
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

/// 状态与错误码可以进入插件日志；响应正文和凭证不能进入诊断。
class MetaverseStreamException extends MetaversePluginCallException {
  const MetaverseStreamException(super.message, {this.status, this.retryAfter, this.retryable = false});
  final int? status;
  final Duration? retryAfter;
  final bool retryable;
}
