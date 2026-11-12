import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

import '../constants.dart';

/// 使用应用会话完成 Connect 导航，业务回调交给调用方处理。
class LinuxDoConnectNavigator {
  LinuxDoConnectNavigator(this.client);

  final Dio client;

  static bool isConnect(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      uri.host == 'connect.linux.do';

  Future<Uri> authorize(
    Uri authorization, {
    required bool Function() active,
  }) async {
    if (!isConnect(authorization)) {
      throw const FormatException('oauth_invalid_init');
    }
    final callback = Uri.tryParse(
      authorization.queryParameters['redirect_uri'] ?? '',
    );
    if (callback == null ||
        callback.scheme != 'https' ||
        callback.host.isEmpty ||
        callback.userInfo.isNotEmpty) {
      throw const FormatException('oauth_invalid_callback');
    }
    var uri = authorization;
    var approved = false;
    for (var hop = 0; hop < 8; hop++) {
      if (!active()) throw const FormatException('oauth_cancelled');
      if (uri.origin == callback.origin && uri.path == callback.path) {
        return uri;
      }
      if (!isConnect(uri) &&
          !(uri.scheme == 'https' &&
              uri.port == 443 &&
              uri.userInfo.isEmpty &&
              uri.host == Uri.parse(AppConstants.baseUrl).host)) {
        throw const FormatException('oauth_invalid_redirect');
      }
      final response = await client.get<String>(
        uri.toString(),
        options: Options(
          headers: {
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
          extra: {
            'skipCsrf': true,
            'skipRedirect': true,
            'allowRedirectSetCookie': true,
          },
        ),
      );
      final location = response.headers.value('location');
      if (location != null) {
        uri = uri.resolve(location);
        continue;
      }
      final link = html
          .parse(response.data ?? '')
          .querySelector('a[href*="/oauth2/approve/"]')
          ?.attributes['href'];
      if (approved || !isConnect(uri) || link == null) {
        throw const FormatException('oauth_approval_unavailable');
      }
      final approval = uri.resolve(link);
      if (!isConnect(approval) ||
          !approval.path.startsWith('/oauth2/approve/')) {
        throw const FormatException('oauth_invalid_approval');
      }
      approved = true;
      uri = approval;
    }
    throw const FormatException('oauth_redirect_limit');
  }
}
