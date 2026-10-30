import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

void main() {
  test('发布新话题带上当前草稿 key，并回写服务端版本号', () async {
    final service = DiscourseService();
    Map? sent;
    final interceptor = InterceptorsWrapper(
      onRequest: (options, handler) {
        sent = options.data as Map;
        handler.resolve(
          Response(
            requestOptions: options,
            data: {
              'post': {'topic_id': 42},
              'target': {'draft_sequence': 7},
            },
          ),
        );
      },
    );
    service.dio.interceptors.insert(0, interceptor);
    addTearDown(() => service.dio.interceptors.remove(interceptor));
    int? sequence;
    final topic = await service.createTopic(
      title: 'draft',
      raw: 'body',
      categoryId: 1,
      draftKey: 'new_topic_saved',
      onDraftSequence: (value) => sequence = value,
    );
    expect(topic, 42);
    expect(sent?['draft_key'], 'new_topic_saved');
    expect(sequence, 7);
  });
}
