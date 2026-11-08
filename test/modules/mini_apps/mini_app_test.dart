import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_directory_controller.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_providers.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_service.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_url.dart';
import 'package:fluxdo/services/auth_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appId = '01a1b3ac-b68b-7d49-883d-51d49c784168';
const app = MiniApp(id: appId, name: 'CS');
MiniAppDirectory page(List<MiniApp> apps, {int page = 0, int total = 3}) =>
    MiniAppDirectory(apps: apps, page: page, perPage: 2, total: total);
MiniAppDetails details({int release = 428, String? favoriteUrl}) =>
    MiniAppDetails(
      app,
      'https://linux.do/apps/$appId',
      configuration: {
        'favoriteUrl':
            favoriteUrl ?? '/mini-app-api/production/$appId/favorite',
        'ratingUrl': '/mini-app-api/production/$appId/rating',
        'tipUrl': '/mini-app-api/production/$appId/tip',
        'reportUrl': '/mini-app-api/production/$appId/report',
      },
      feedback: {'release_id': release},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only exact site app routes become native routes; startup parameters survive', () {
    for (final value in [
      'https://linux.do.evil.test/apps/$appId',
      'https://other.linux.do/apps/$appId',
      'https://user@linux.do/apps/$appId',
      'http://linux.do/apps/$appId',
      'https://linux.do:444/apps/$appId',
      '/mini-app-api/production/$appId/runtime',
      '/apps/not-a-uuid',
      '/apps/$appId/extra',
      r'https://linux.do\@evil.test/apps',
    ]) {
      expect(
        MiniAppUrl.parse(value, 'https://linux.do'),
        isNull,
        reason: value,
      );
    }
    expect(
      MiniAppUrl.appId(MiniAppUrl.parse('/apps', 'https://linux.do')!),
      isNull,
    );
    final entry = MiniAppUrl.embed(
      '/apps/$appId?room=a&room=b#join',
      appId,
      'https://linux.do',
    );
    expect(entry.queryParametersAll['room'], ['a', 'b']);
    expect(entry.queryParameters['embed_mode'], 'true');
    expect(entry.fragment, 'join');
  });

  test(
    'late search and pagination results cannot cross query generations',
    () async {
      final pending = <Completer<MiniAppDirectory>>[];
      final controller = MiniAppDirectoryController(({
        required sort,
        required query,
        required favorites,
        required page,
      }) {
        final completer = Completer<MiniAppDirectory>();
        pending.add(completer);
        return completer.future;
      });
      final old = controller.refresh();
      final latest = controller.update(query: 'new');
      pending[1].complete(page([app]));
      await latest;
      pending[0].complete(page([const MiniApp(id: 'old', name: 'Old')]));
      await old;
      expect(controller.apps.single.id, appId);

      final more = controller.loadMore();
      controller.invalidate();
      pending[2].complete(
        page([const MiniApp(id: 'stale', name: 'Stale')], page: 1),
      );
      await more;
      expect(controller.apps.single.id, appId);
      expect(controller.loadingMore, isFalse);
      controller.dispose();
    },
  );

  test(
    'pagination deduplicates app IDs and follows server page size',
    () async {
      var calls = 0;
      final controller = MiniAppDirectoryController(({
        required sort,
        required query,
        required favorites,
        required page,
      }) async {
        calls++;
        return page == 0
            ? MiniAppDirectory(apps: [app], page: 0, perPage: 1, total: 2)
            : MiniAppDirectory(
                apps: [
                  app,
                  const MiniApp(id: 'second', name: 'Second'),
                ],
                page: 1,
                perPage: 1,
                total: 2,
              );
      });
      await controller.refresh();
      expect(controller.hasMore, isTrue);
      await Future.wait([controller.loadMore(), controller.loadMore()]);
      expect(calls, 2);
      expect(controller.apps.map((e) => e.id), [appId, 'second']);
      expect(controller.hasMore, isFalse);
      controller.dispose();
    },
  );

  test('personal recents stay isolated by site and account, and persist without grants', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = MiniAppRecents(prefs, 'https://linux.do|1');
    first.record(app);
    first.record(app);
    expect(first.apps, hasLength(1));
    expect(MiniAppRecents(prefs, 'https://linux.do|2').apps, isEmpty);
    expect(MiniAppRecents(prefs, 'https://other.test|1').apps, isEmpty);
    expect(MiniAppRecents(prefs, 'https://linux.do|1').apps.single.id, appId);
    expect(
      prefs.getString('mini_app_recents_https://linux.do|1'),
      isNot(contains('configuration')),
    );
    first.dispose();
  });

  test(
    'write operations reject untrusted URLs and preserve tip idempotency keys',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'));
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(
              Response(requestOptions: options, data: {'is_favorited': true}),
            );
          },
        ),
      );
      final api = MiniAppService(dio: dio);
      expect(
        () => api.actionUrl(
          details(favoriteUrl: 'https://evil.test/steal'),
          'favorite',
        ),
        throwsFormatException,
      );
      expect(
        () => api.actionUrl(
          details(favoriteUrl: '/mini-app-api/production/other/favorite'),
          'favorite',
        ),
        throwsFormatException,
      );
      await api.favorite(details(), true);
      await api.favorite(details(), false);
      await api.rate(details(), 4);
      await api.tip(details(), 3, 'same-request');
      await api.tip(details(), 3, 'same-request');
      expect(requests.map((e) => e.method), [
        'PUT',
        'DELETE',
        'PUT',
        'POST',
        'POST',
      ]);
      expect(requests[2].data, {'score': 4});
      expect(requests[3].data, requests[4].data);
      await expectLater(api.rate(details(), 0), throwsFormatException);
      expect(requests, hasLength(5));
      dio.close();
    },
  );

  test(
    'report cannot target a changed release or cross an account switch',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'));
      var release = 429;
      var changeAccount = false;
      var posts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'POST') posts++;
            if (changeAccount) AuthSession().advance();
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'app': {'app_id': appId, 'name': 'CS', 'release_id': release},
                  'configuration': {'embedUrl': 'https://linux.do/apps/$appId'},
                },
              ),
            );
          },
        ),
      );
      final api = MiniAppService(dio: dio);
      await expectLater(
        api.report(details(), 4, 'test'),
        throwsFormatException,
      );
      release = 428;
      changeAccount = true;
      await expectLater(api.report(details(), 4, 'test'), throwsStateError);
      expect(posts, 0);
      dio.close();
    },
  );

  test(
    'report types use the site post-action flag metadata and app applicability',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'post_action_types': [
                    {
                      'id': 20,
                      'name_key': 'custom',
                      'is_flag': true,
                      'enabled': true,
                      'applies_to': ['DiscourseMiniApp::App'],
                    },
                    {
                      'id': 3,
                      'name_key': 'notify_user',
                      'is_flag': true,
                      'enabled': true,
                      'applies_to': ['DiscourseMiniApp::App'],
                    },
                    {
                      'id': 4,
                      'is_flag': true,
                      'enabled': true,
                      'applies_to': ['Post'],
                    },
                    {
                      'id': 5,
                      'is_flag': true,
                      'enabled': false,
                      'applies_to': ['DiscourseMiniApp::App'],
                    },
                    {
                      'id': 6,
                      'is_flag': false,
                      'enabled': true,
                      'applies_to': ['DiscourseMiniApp::App'],
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      expect(
        (await MiniAppService(dio: dio).reportTypes()).map((e) => e['id']),
        [20],
      );
      dio.close();
    },
  );
}
