import '../models/topic.dart';

/// 置顶分组的展示状态。手动操作保持到未读状态变化或切换筛选为止。
class PinnedTopicsController {
  Object? _identity;
  List<Topic>? _source;
  Set<int> _unreadTopicIds = {};
  bool expanded = false;
  List<Topic> pinned = const [];
  List<Topic> visible = const [];

  int get unreadCount => _unreadTopicIds.length;

  void update(List<Topic> topics, {required Object identity}) {
    if (_identity == identity && identical(_source, topics)) return;
    _source = topics;
    pinned = topics.where((topic) => topic.pinned).toList();
    final unread = {
      for (final topic in pinned)
        if (topic.isUnseenTopic) topic.id,
    };
    final hasNewUnread = unread.difference(_unreadTopicIds).isNotEmpty;
    if (_identity != identity || hasNewUnread) {
      expanded = unread.isNotEmpty;
    } else if (_unreadTopicIds.isNotEmpty && unread.isEmpty) {
      expanded = false;
    }
    _identity = identity;
    _unreadTopicIds = unread;
    // 稳定分组，普通话题的原有排序和各卡片的稳定标识保持不变。
    visible = pinned.isEmpty
        ? topics
        : [if (expanded) ...pinned, ...topics.where((topic) => !topic.pinned)];
  }

  void toggle() {
    expanded = !expanded;
    _source = null;
  }
}
