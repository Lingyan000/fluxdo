import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

import '../../../constants.dart';
import '../../../services/network/discourse_dio.dart';
import 'metaverse_checkout_types.dart';
import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_service_session.dart';
import 'runtime/metaverse_plugin_runtime.dart';

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
      throw const MetaversePluginCallException('oauth_invalid_callback');
    }
    Uri? approve;
    for (var hop = 0; hop < 8; hop++) {
      if (!active()) {
        throw const MetaversePluginCallException('oauth_cancelled');
      }
      if (uri!.origin == callback.origin && uri.path == callback.path) {
        final parameters = Uri.splitQueryString(uri.fragment);
        final encoded =
            parameters['ldsp_oauth'] ?? uri.queryParameters['ldsp_oauth'];
        if (encoded == null || encoded.length > 32768) {
          throw const MetaversePluginCallException('oauth_invalid_handoff');
        }
        final handoff = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
        );
        if (handoff is! Map ||
            handoff['s'] != state ||
            handoff['exp'] is! int ||
            handoff['exp'] <= 0 ||
            handoff['c'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(handoff['c'])) {
          throw const MetaversePluginCallException('oauth_state_mismatch');
        }
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
        if (uri.scheme != 'https' ||
            uri.port != 443 ||
            uri.userInfo.isNotEmpty) {
          throw const MetaversePluginCallException('oauth_invalid_redirect');
        }
        final response = await _connect.get<String>(
          uri.toString(),
          options: Options(
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
        if (uri.origin != serviceCallback.origin ||
            uri.path != serviceCallback.path) {
          throw const MetaversePluginCallException('oauth_invalid_redirect');
        }
        final response = await network.fetch(
          manifest,
          request: {'url': '$uri'},
          authToken: null,
        );
        body = response['body'] as String;
        location = (response['headers'] as Map)['location'] as String?;
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
          'Origin': Uri.parse(manifest.auth.connect!['callback']!).origin,
          if (body != null) 'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        if (body != null) 'body': jsonEncode(body),
      },
      authToken: null,
    );
    final result = jsonDecode(response['body'] as String);
    if (response['status'] != 200 ||
        result is! Map ||
        result['success'] != true) {
      throw const MetaversePluginCallException('oauth_service_error');
    }
    return result['data'] is Map ? result['data'] as Map : result;
  }

  void dispose() => _connect.close(force: true);
}
