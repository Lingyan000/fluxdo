import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/tag_notification_level.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('读取标签订阅使用独立接口，并解析 tag_notification 中的五档级别', () async {
    final service = DiscourseService();
    var responseLevel = 0;
    final requests = <RequestOptions>[];
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(
          Response(
            requestOptions: options,
            data: {
              'tag_notification': {
                'id': 42,
                'name': '开发#C++',
                'notification_level': responseLevel,
              },
            },
          ),
        );
      },
    );
    service.dio.interceptors.insert(0, interceptor);
    addTearDown(() => service.dio.interceptors.remove(interceptor));

    for (final level in TagNotificationLevel.values) {
      responseLevel = level.value;
      expect(await service.getTagNotificationLevel('开发#C++'), level);
      expect(requests.last.method, 'GET');
      expect(requests.last.uri.pathSegments, [
        'tag',
        '开发#C++',
        'notifications.json',
      ]);
      expect(requests.last.uri.fragment, isEmpty);
    }
  });

  test('保存标签订阅使用 PUT 和嵌套表单参数', () async {
    final service = DiscourseService();
    final requests = <RequestOptions>[];
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(Response(requestOptions: options, data: {}));
      },
    );
    service.dio.interceptors.insert(0, interceptor);
    addTearDown(() => service.dio.interceptors.remove(interceptor));

    for (final level in TagNotificationLevel.values) {
      await service.setTagNotificationLevel('开发#C++', level);
      final request = requests.last;
      expect(request.method, 'PUT');
      expect(request.uri.pathSegments, ['tag', '开发#C++', 'notifications.json']);
      expect(request.uri.fragment, isEmpty);
      expect(request.contentType, Headers.formUrlEncodedContentType);
      expect(request.data, {
        'tag_notification': {'notification_level': level.value},
      });
    }
  });
}
