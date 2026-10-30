import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('增量加载保留列表路径、子集、标签与排序参数', () async {
    final service = DiscourseService();
    final requests = <RequestOptions>[];
    final interceptor = InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response(
            requestOptions: request,
            data: {
              'topic_list': {
                'topics': [],
                'tags': [
                  {'id': 42, 'name': 'dart'},
                ],
              },
            },
          ),
        );
      },
    );
    service.dio.interceptors.insert(0, interceptor);
    addTearDown(() => service.dio.interceptors.remove(interceptor));
    final response = await service.getFilteredTopics(
      filter: 'new',
      categoryId: 2,
      categorySlug: 'dev',
      parentCategorySlug: 'tech',
      tags: ['dart'],
      subset: 'replies',
      order: 'created',
      ascending: true,
      topicIds: [11, 12],
    );
    expect(requests.single.path, '/c/tech/dev/2/l/new.json');
    expect(requests.single.queryParameters, {
      'tags[]': ['dart'],
      'subset': 'replies',
      'order': 'created',
      'ascending': 'true',
      'topic_ids': '11,12',
    });
    expect(response.tags.single.id, 42);
    await service.getFilteredTopics(
      filter: 'unread',
      tags: ['dart', 'flutter'],
      topicIds: [11],
    );
    expect(requests.last.path, '/tag/dart/l/unread.json');
    expect(requests.last.queryParameters, {
      'tags[]': ['flutter'],
      'match_all_tags': 'true',
      'topic_ids': '11',
    });
  });
}
