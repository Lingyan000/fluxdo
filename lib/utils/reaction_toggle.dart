import '../models/topic.dart';

/// 本地乐观切换回应,返回切换后的(回应列表, 我的回应)。
///
/// 规则与官方 discourse-reactions `toggleReaction` 一致:
/// - 先撤掉我原来的回应:计数 -1,减到 0 移除
/// - 点的是另一个表情:该表情计数 +1;列表里没有就按「计数降序、同计数
///   按 id 升序」找到位置插入(只定位新项,不重排其余项)
/// - 点的正是我原来的回应:即取消,我的回应置空
///
/// 不修改入参,返回新列表。
(List<PostReaction>, PostReaction?) applyReactionToggle(
  List<PostReaction> reactions,
  PostReaction? current,
  String reactionId,
) {
  final list = [...reactions];

  if (current != null) {
    final i = list.indexWhere((r) => r.id == current.id);
    if (i >= 0) {
      final r = list[i];
      if (r.count <= 1) {
        list.removeAt(i);
      } else {
        list[i] = PostReaction(id: r.id, type: r.type, count: r.count - 1);
      }
    }
  }

  if (current?.id == reactionId) return (list, null);

  final i = list.indexWhere((r) => r.id == reactionId);
  if (i >= 0) {
    final r = list[i];
    list[i] = PostReaction(id: r.id, type: r.type, count: r.count + 1);
  } else {
    final added = PostReaction(id: reactionId, type: 'emoji', count: 1);
    final sorted = [...list, added]
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.id.compareTo(b.id);
      });
    list.insert(sorted.indexOf(added), added);
  }
  return (list, PostReaction(id: reactionId, type: 'emoji', count: 0));
}
