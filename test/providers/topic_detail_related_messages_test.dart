import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final filtered in [false, true]) {
    test('私信翻页补全相关消息，重载以服务端空列表为准 filtered=$filtered', () async {
      final service = DiscourseService();
      final pageRequests = <RequestOptions>[];
      List<Map<String, dynamic>>? detailMessages;
      final interceptor = InterceptorsWrapper(
        onRequest: (request, handler) {
          final isPage = request.path == '/t/42/posts.json';
          if (isPage) pageRequests.add(request);
          final number = isPage ? pageRequests.length + 1 : 1;
          final body = {
            'id': 42,
            'title': '读书会',
            'archetype': 'private_message',
            'posts_count': 3,
            'post_stream': {
              'stream': [1, 2, 3],
              'posts': [
                {'id': number, 'post_number': number, 'username': 'reader'},
              ],
            },
            'suggested_topics': [
              {'id': 45, 'title': '另一条推荐'},
            ],
            if (isPage &&
                request.queryParameters['include_suggested'] == 'true')
              'related_messages': [
                {'id': 43, 'title': '下次读什么'},
              ]
            else if (!isPage && detailMessages != null)
              'related_messages': detailMessages,
          };
          handler.resolve(
            Response<String>(
              requestOptions: request,
              statusCode: 200,
              data: jsonEncode(body),
            ),
          );
        },
      );
      service.dio.interceptors.insert(0, interceptor);
      addTearDown(() => service.dio.interceptors.remove(interceptor));
      final container = ProviderContainer(
        overrides: [discourseServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final provider = topicDetailProvider(const TopicDetailParams(42));
      container.listen(provider, (_, _) {});
      final initial = await container.read(provider.future);
      expect(initial.relatedMessages, isNull);
      final notifier = container.read(provider.notifier);
      if (filtered) await notifier.showAuthorOnly('reader');
      await notifier.loadMore();
      expect(pageRequests.single.queryParameters['include_suggested'], 'true');
      expect(
        container.read(provider).requireValue.relatedMessages!.single.id,
        43,
      );

      await notifier.loadMore();
      expect(
        pageRequests.last.queryParameters,
        isNot(contains('include_suggested')),
      );
      await notifier.reloadWithPostNumber(1);
      expect(
        container.read(provider).requireValue.relatedMessages!.single.id,
        43,
      );
      detailMessages = [];
      await notifier.refreshWithPostNumber(1);
      expect(container.read(provider).requireValue.relatedMessages, isEmpty);
      detailMessages = null;
      await notifier.reloadWithPostNumber(1);
      expect(container.read(provider).requireValue.relatedMessages, isEmpty);
      expect(container.read(provider).requireValue.needsFooterTopics, isFalse);
    });
  }
}
