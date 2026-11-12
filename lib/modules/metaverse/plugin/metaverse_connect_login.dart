import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

import '../../../constants.dart';
import '../../../l10n/s.dart';
import '../../../services/log/log_writer.dart';
import '../../../services/network/discourse_dio.dart';
import 'metaverse_checkout_types.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_service_session.dart';
import 'runtime/metaverse_plugin_runtime.dart';

class MetaverseLoginException extends MetaversePluginCallException {
  const MetaverseLoginException(
    super.message, {
    this.status,
    this.callbackHost,
    this.reason,
    this.serviceCode,
    this.responseType,
    this.requestId,
  });
  final int? status;
  final String? callbackHost;
  final String? reason;
  final String? serviceCode;
  final String? responseType;
  final String? requestId;
}

enum _LoginStage {
  initialize,
  authorization,
  callback,
  exchange,
  verification;

  String get label => switch (this) {
    initialize => S.current.metaverse_loginInitialize,
    authorization => S.current.metaverse_loginAuthorization,
    callback => S.current.metaverse_loginCallback,
    exchange => S.current.metaverse_loginExchange,
    verification => S.current.metaverse_loginVerification,
  };
}

/// 在宿主内完成 Connect 同意、业务回调和 PKCE 交换。
/// 论坛 Cookie 仅用于 Connect 导航，业务 API 使用独立插件网络。
class MetaverseConnectLogin {
  MetaverseConnectLogin(this.network, {Dio? connectClient})
    : _connect =
          connectClient ??
          DiscourseDio.create(
            enableNetworkLog: false,
            enableRetry: false,
            enableCfChallenge: false,
          );

  final MetaversePluginNetwork network;
  final Dio _connect;

  Future<MetaverseServiceSession> authorize(
    MetaversePluginManifest manifest, {
    required int accountId,
    required bool Function() active,
  }) async {
    var stage = _LoginStage.initialize;
    try {
      return await _authorize(
        manifest,
        accountId: accountId,
        active: active,
        onStage: (value) => stage = value,
      );
    } catch (error) {
      final status = switch (error) {
        DioException e => e.response?.statusCode,
        MetaverseLoginException e => e.status,
        _ => null,
      };
      final reason = switch (error) {
        DioException e => e.type.name,
        MetaversePluginCallException e
            when RegExp(r'^oauth_[a-z_]+$').hasMatch(e.message) =>
          e.message,
        FormatException() => 'invalid_response',
        _ => 'request_failed',
      };
      final failure = error is MetaverseLoginException ? error : null;
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'message':
            '[插件授权] ${manifest.id} version=${manifest.version} '
            'stage=${stage.name} reason=$reason'
            '${status == null ? '' : ' HTTP=$status'}'
            '${failure?.serviceCode == null ? '' : ' serviceCode=${failure!.serviceCode}'}'
            '${failure?.responseType == null ? '' : ' responseType=${failure!.responseType}'}',
        'pluginVersion': manifest.version,
        if (failure?.callbackHost != null)
          'callbackHost': failure!.callbackHost,
        if (failure?.requestId != null) 'requestId': failure!.requestId,
      });
      throw MetaverseLoginException(
        reason == 'oauth_invalid_callback'
            ? S.current.metaverse_loginCallbackNotDeclared
            : failure?.serviceCode == 'OAUTH_REAUTHORIZE_REQUIRED'
            ? S.current.metaverse_loginRestartRequired
            : status != null
            ? S.current.metaverse_loginResponseFailed(stage.label, '$status')
            : S.current.metaverse_loginStageFailed(stage.label),
        status: status,
        reason: reason,
        callbackHost: failure?.callbackHost,
        serviceCode: failure?.serviceCode,
        responseType: failure?.responseType,
        requestId: failure?.requestId,
      );
    }
  }

  Future<MetaverseServiceSession> _authorize(
    MetaversePluginManifest manifest, {
    required int accountId,
    required bool Function() active,
    required void Function(_LoginStage) onStage,
  }) async {
    final config = manifest.auth.connect!;
    final random = Random.secure();
    final verifier = List.generate(
      32,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final callback = Uri.parse(config['callback']!);
    final init = Uri.parse(config['init']!).replace(
      queryParameters: {
        'site': 'linux.do',
        'return_url': callback.toString(),
        'code_challenge': challenge,
      },
    );
    final initial = await _json(manifest, init);
    final state = initial['state'];
    var uri = Uri.tryParse('${initial['auth_url']}');
    if (state is! String || state.isEmpty || uri == null || !_isConnect(uri)) {
      throw const MetaversePluginCallException('oauth_invalid_init');
    }
    final serviceCallback = Uri.tryParse(
      uri.queryParameters['redirect_uri'] ?? '',
    );
    if (serviceCallback == null ||
        serviceCallback.scheme != 'https' ||
        !manifest.networkHosts.contains(serviceCallback.host)) {
      throw MetaverseLoginException(
        'oauth_invalid_callback',
        callbackHost: serviceCallback?.host,
      );
    }
    Uri? approve;
    for (var hop = 0; hop < 8; hop++) {
      if (!active()) {
        throw const MetaversePluginCallException('oauth_cancelled');
      }
      if (uri!.origin == callback.origin && uri.path == callback.path) {
        onStage(_LoginStage.callback);
        final handoff = _readHandoff(uri);
        if (handoff is! Map ||
            handoff['s'] != state ||
            handoff['exp'] is! int ||
            handoff['exp'] <= 0 ||
            handoff['c'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(handoff['c'])) {
          throw const MetaversePluginCallException('oauth_state_mismatch');
        }
        onStage(_LoginStage.exchange);
        final exchanged = await _json(
          manifest,
          Uri.parse(config['exchange']!),
          body: {
            'code': handoff['c'],
            'state': state,
            'verifier': verifier,
            'origin': callback.origin,
          },
        );
        final token = exchanged['token'];
        if (token is! String || token.split('.').length != 3) {
          throw const MetaversePluginCallException('oauth_invalid_session');
        }
        onStage(_LoginStage.verification);
        final verified = await _json(
          manifest,
          Uri.parse(config['verify']!),
          token: token,
        );
        final user = verified['user'];
        final claims = jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(token.split('.')[1])),
          ),
        );
        if (!active() ||
            verified['authenticated'] != true ||
            user is! Map ||
            claims is! Map ||
            '${user['id']}' != '$accountId' ||
            '${claims['sub'] ?? claims['id']}' != '$accountId' ||
            (user['site'] ?? 'linux.do') != 'linux.do' ||
            (claims['site'] ?? 'linux.do') != 'linux.do' ||
            claims['exp'] is! int ||
            claims['exp'] * 1000 <= DateTime.now().millisecondsSinceEpoch) {
          throw const MetaversePluginCallException('oauth_identity_mismatch');
        }
        return MetaverseServiceSession(
          token,
          accountId: accountId,
          expiresAt: claims['exp'] as int,
          queryUrls: manifest.auth.queries.values,
          checkout: manifest.auth.checkout == null
              ? null
              : MetaverseCheckoutGrant(
                  manifest.auth.checkout!,
                  subject: 'linux.do:$accountId',
                  displayName: '${user['username'] ?? accountId}',
                  unit: 'LDC',
                ),
        );
      }
      final String body;
      final String? location;
      if (_isConnect(uri) || uri.host == Uri.parse(AppConstants.baseUrl).host) {
        onStage(_LoginStage.authorization);
        if (uri.scheme != 'https' ||
            uri.port != 443 ||
            uri.userInfo.isNotEmpty) {
          throw const MetaversePluginCallException('oauth_invalid_redirect');
        }
        final response = await _connect.get<String>(
          uri.toString(),
          options: Options(
            headers: {'Accept': _navigationAccept},
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (s) => s != null && s < 400,
            extra: {
              'skipCsrf': true,
              'skipRedirect': true,
              'allowRedirectSetCookie': true,
            },
          ),
        );
        body = response.data ?? '';
        location = response.headers.value('location');
      } else {
        onStage(_LoginStage.callback);
        if (uri.origin != serviceCallback.origin ||
            uri.path != serviceCallback.path) {
          throw const MetaversePluginCallException('oauth_invalid_redirect');
        }
        final response = await network.fetch(
          manifest,
          request: {
            'url': '$uri',
            'headers': {
              'Accept': _navigationAccept,
              'User-Agent': await AppConstants.getUserAgent(),
            },
          },
          authToken: null,
        );
        body = response['body'] as String;
        location = (response['headers'] as Map)['location'] as String?;
        final status = response['status'] as int?;
        // 业务回调与 Connect 同意页是两个协议阶段。服务端错误不能再被
        // 当成缺失同意按钮，也不能刷新同一个回调来重放一次性授权码。
        if (status == null ||
            status < 300 ||
            status >= 400 ||
            location == null ||
            location.trim().isEmpty) {
          throw _responseFailure(
            response,
            uri,
            reason: 'oauth_callback_response',
          );
        }
      }
      if (location != null) {
        uri = uri.resolve(location);
        continue;
      }
      final link = html
          .parse(body)
          .querySelector('a[href*="/oauth2/approve/"]')
          ?.attributes['href'];
      if (!_isConnect(uri) || link == null || approve != null) {
        throw const MetaversePluginCallException('oauth_approval_unavailable');
      }
      approve = uri.resolve(link);
      if (!_isConnect(approve) ||
          !approve.path.startsWith('/oauth2/approve/')) {
        throw const MetaversePluginCallException('oauth_invalid_approval');
      }
      uri = approve;
    }
    throw const MetaversePluginCallException('oauth_redirect_limit');
  }

  static bool _isConnect(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.host == 'connect.linux.do';

  static const _navigationAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

  static MetaverseLoginException _responseFailure(
    Map<String, Object?> response,
    Uri uri, {
    required String reason,
  }) {
    final headers = response['headers'] as Map;
    final contentType = '${headers['content-type'] ?? ''}'
        .split(';')
        .first
        .trim()
        .toLowerCase();
    final responseType = switch (contentType) {
      'application/json' => 'json',
      'text/html' => 'html',
      _ => 'other',
    };
    String? serviceCode;
    try {
      final result = jsonDecode(response['body'] as String);
      if (result is Map && result['success'] == false) {
        final error = result['error'];
        final code = error is Map ? error['code'] : result['code'];
        // 仅保留有界的协议错误标识，绝不输出响应正文、消息和授权参数。
        if (code is String && RegExp(r'^[A-Z][A-Z_]{2,63}$').hasMatch(code)) {
          serviceCode = code;
        }
      }
    } on FormatException {
      // 网关错误页和验证页不一定是 JSON。
    }
    final requestId = headers['x-request-id'];
    return MetaverseLoginException(
      reason,
      status: response['status'] as int?,
      callbackHost: uri.host,
      responseType: responseType,
      serviceCode: serviceCode,
      requestId:
          requestId is String &&
              RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(requestId)
          ? requestId
          : null,
    );
  }

  static Object? _readHandoff(Uri uri) {
    // 与网页一致地保留标准 Base64 的 +，兼容 URL 编码和百分号编码的 JSON。
    final parameter = RegExp(r'(?:^|&)ldsp_oauth=([^&]*)');
    final raw =
        parameter.firstMatch(uri.fragment)?.group(1) ??
        parameter.firstMatch(uri.query)?.group(1);
    if (raw == null || raw.length > 32768) {
      throw const MetaversePluginCallException('oauth_invalid_handoff');
    }
    final encoded = Uri.decodeComponent(raw).replaceAll(RegExp(r'\s'), '+');
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    try {
      return jsonDecode(decoded);
    } on FormatException {
      return jsonDecode(Uri.decodeComponent(decoded));
    }
  }

  Future<Map> _json(
    MetaversePluginManifest manifest,
    Uri uri, {
    Map<String, Object?>? body,
    String? token,
  }) async {
    final response = await network.fetch(
      manifest,
      request: {
        'url': '$uri',
        'method': body == null ? 'GET' : 'POST',
        'headers': {
          'Accept': 'application/json',
          'User-Agent': await AppConstants.getUserAgent(),
          'Origin': Uri.parse(manifest.auth.connect!['callback']!).origin,
          if (body != null) 'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        if (body != null) 'body': jsonEncode(body),
      },
      authToken: null,
    );
    Object? result;
    try {
      result = jsonDecode(response['body'] as String);
    } on FormatException {
      throw _responseFailure(response, uri, reason: 'oauth_service_error');
    }
    if (response['status'] != 200 ||
        result is! Map ||
        result['success'] != true) {
      throw _responseFailure(response, uri, reason: 'oauth_service_error');
    }
    return result['data'] is Map ? result['data'] as Map : result;
  }

  void dispose() => _connect.close(force: true);
}
