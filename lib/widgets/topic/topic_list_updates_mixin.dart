import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/topic.dart';
import '../../providers/category_provider.dart';
import '../../providers/message_bus/topic_list_events.dart';
import '../../providers/message_bus/topic_tracking_providers.dart';
import '../../services/app_error_handler.dart';
import '../../services/preloaded_data_service.dart';
import '../../utils/topic_list_updates.dart';

export '../../utils/topic_list_updates.dart';

mixin TopicListUpdatesMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  final topicUpdates = TopicListUpdates();
  int? _loadingUpdatesGeneration;

  bool get newNewViewEnabled =>
      PreloadedDataService().currentUserSync?['new_new_view_enabled'] == true;

  bool get isLoadingTopicUpdates =>
      _loadingUpdatesGeneration == topicUpdates.generation;

  Map<int, int> get topicUpdateSnapshot => topicUpdates.snapshot({
    for (final category in (ref.read(categoryMapProvider).value ?? {}).values)
      category.id: category.parentCategoryId,
  });

  void watchTopicUpdates(
    TopicListUpdateQuery query, {
    Iterable<Tag> tags = const [],
  }) {
    topicUpdates.configure(query);
    topicUpdates.rememberTags(tags);
    ref.watch(messageBusInitProvider);
    ref.watch(categoryMapProvider);
    ref.listen(topicListEventsProvider, (_, event) {
      if (event == null) return;
      final before = topicUpdateSnapshot.length;
      if (topicUpdates.add(event) && topicUpdateSnapshot.length != before) {
        setState(() {});
      }
    });
  }

  ({int generation, Map<int, int> snapshot}) beginTopicUpdatesRefresh(
    TopicListUpdateQuery query,
  ) {
    topicUpdates.configure(query);
    topicUpdates.generation++;
    return (generation: topicUpdates.generation, snapshot: topicUpdateSnapshot);
  }

  bool isCurrentTopicUpdatesRefresh(int generation) =>
      mounted && generation == topicUpdates.generation;

  void completeTopicUpdatesRefresh(
    Map<int, int> snapshot,
    TopicListResponse response,
  ) {
    topicUpdates.rememberTags([
      ...response.tags,
      for (final topic in response.topics) ...topic.tags,
    ]);
    topicUpdates.acknowledge(snapshot);
  }

  Future<List<int>> loadTopicUpdates(
    Future<List<int>?> Function(List<int> ids) load,
  ) async {
    if (isLoadingTopicUpdates) return [];
    final snapshot = topicUpdateSnapshot;
    if (snapshot.isEmpty) return [];
    final generation = ++topicUpdates.generation;
    setState(() => _loadingUpdatesGeneration = generation);
    try {
      final inserted = await load(snapshot.keys.toList());
      if (!mounted ||
          generation != topicUpdates.generation ||
          inserted == null) {
        return [];
      }
      topicUpdates.acknowledge(snapshot);
      return inserted;
    } on DioException catch (_) {
      // 网络层负责显示错误，保留队列以便再次点击重试。
      return [];
    } catch (error, stack) {
      AppErrorHandler.handleUnexpected(error, stack);
      return [];
    } finally {
      if (mounted && _loadingUpdatesGeneration == generation) {
        setState(() => _loadingUpdatesGeneration = null);
      }
    }
  }
}
