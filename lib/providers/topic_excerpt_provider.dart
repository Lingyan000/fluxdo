import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../services/topic_excerpt_service.dart';
import 'core_providers.dart';

/// 话题摘要服务 Provider
final topicExcerptServiceProvider = Provider<TopicExcerptService>((ref) {
  return TopicExcerptService();
});

/// 针对单个 Topic 的摘要内容 FutureProvider
final topicExcerptFamily = FutureProvider.family<TopicExcerptData?, Topic>((ref, topic) {
  final service = ref.watch(topicExcerptServiceProvider);
  final discourse = ref.watch(discourseServiceProvider);

  return service.getOrFetchExcerpt(
    topic.id,
    fallbackRaw: topic.excerpt,
    service: discourse,
  );
});
