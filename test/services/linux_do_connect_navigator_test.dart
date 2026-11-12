import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/linux_do_connect_navigator.dart';

void main() {
  for (final explicit in [true, false]) {
    test('Connect 返回业务回调，显式回调参数为 $explicit', () async {
      final dio = Dio();
      addTearDown(dio.close);
      final requests = <Uri>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options.uri);
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 302,
                headers: Headers.fromMap({
                  'location': [
                    'https://credit.linux.do/oauth/callback?code=fixture&state=fixture',
                  ],
                }),
              ),
            );
          },
        ),
      );
      final authorization = Uri.https('connect.linux.do', '/oauth2/authorize', {
        'client_id': 'fixture',
        if (explicit) 'redirect_uri': 'https://credit.linux.do/oauth/callback',
      });
      final callback = await LinuxDoConnectNavigator(dio).authorize(
        authorization,
        active: () => true,
        callbackOrigin: Uri.https('credit.linux.do'),
      );
      expect(callback.queryParameters['code'], 'fixture');
      expect(requests, [authorization]);
    });
  }
}
