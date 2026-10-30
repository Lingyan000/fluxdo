import 'package:flutter_riverpod/flutter_riverpod.dart';

class TopicListEvent {
  const TopicListEvent({
    required this.topicId,
    required this.type,
    this.categoryId,
    this.tags = const [],
  });

  final int topicId;
  final String type;
  final int? categoryId;
  final List<dynamic> tags;
}

// 只广播经过追踪状态静音过滤的事件；待更新队列由每个列表独立维护。
class TopicListEventsNotifier extends Notifier<TopicListEvent?> {
  @override
  TopicListEvent? build() => null;

  void publish(TopicListEvent event) => state = event;
}

final topicListEventsProvider =
    NotifierProvider<TopicListEventsNotifier, TopicListEvent?>(
      TopicListEventsNotifier.new,
    );
