import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = DiscourseService();
  Object? reply;
  final requests = <RequestOptions>[];
  late InterceptorsWrapper mock;
  setUp(() {
    requests.clear();
    reply = {'success': 'OK'};
    mock = InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(Response(requestOptions: options, data: reply));
      },
    );
    service.dio.interceptors.insert(0, mock);
  });
  tearDown(() => service.dio.interceptors.remove(mock));

  test('可信会话识别 Discourse 的 OK 和 FAILED 响应', () async {
    expect(await service.isPreferenceSessionTrusted(), true);
    reply = {'failed': 'FAILED'};
    expect(await service.isPreferenceSessionTrusted(), false);
  });

  test('偏好变更沿用表单编码并关闭自动重放', () async {
    await service.saveForumPreferences('user name', {
      'watched_category_ids': [-1],
      'user_fields': {'4': 'false'},
    });
    final request = requests.single;
    expect(request.path, '/u/user%20name.json');
    expect(request.contentType, Headers.formUrlEncodedContentType);
    expect(request.listFormat, ListFormat.multiCompatible);
    expect(
      Uri.decodeQueryComponent(
        Transformer.urlEncodeMap(
          request.data as Map<String, dynamic>,
          request.listFormat,
        ),
      ),
      'watched_category_ids[]=-1&user_fields[4]=false',
    );
    expect(request.extra['noRecovery'], true);
    expect(request.extra['skipNetworkLog'], true);
    expect(request.data, {
      'watched_category_ids': [-1],
      'user_fields': {'4': 'false'},
    });
  });

  test('HTTP 200 中的 FAILED 仍然视为失败', () async {
    reply = {'failed': 'FAILED', 'message': 'forbidden'};
    await expectLater(
      service.saveForumPreferences('tester', {'name': '新名'}),
      throwsStateError,
    );
    expect(requests.length, 1);
  });

  test('空响应撤销成功，HTML 响应不能当成保存成功', () async {
    reply = '';
    await service.preferenceCalendarSubscription(revoke: true);
    expect(requests.single.method, 'DELETE');
    reply = '<html>sign in</html>';
    await expectLater(
      service.saveForumPreferences('tester', {'name': '新名'}),
      throwsFormatException,
    );
  });

  test('收藏徽章切换不自动重放', () async {
    await service.toggleFavoriteUserBadge(12);
    expect(requests.single.path, '/user_badges/12/toggle_favorite');
    expect(requests.single.extra['noRecovery'], true);
  });
}
