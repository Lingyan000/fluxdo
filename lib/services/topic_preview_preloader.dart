import 'discourse/discourse_service.dart';

/// 话题预览主贴预加载器。
///
/// 长按意图一出现(移动端按住不动 ~250ms、桌面端右键按下)就发起
/// firstPost 请求;等长按判定完成、弹窗打开时(再隔 ~250ms+),正文
/// 多数已在路上甚至就绪 —— 弹窗 initState 直接 await 同一个 Future,
/// 快网络下零等待。
///
/// 缓存语义:每个 topicId 仅一份在途 Future,[take] 一次性消费即移除;
/// 30s 过期;上限 8 项防泄漏(超出先清过期、再清最旧)。请求失败不在
/// 此兜底 —— Future 带着错误交给弹窗 catch(走 excerpt 降级),缓存
/// 已被消费移除,下次长按自然重新请求。
class TopicPreviewPreloader {
  TopicPreviewPreloader._();

  static final _entries = <int, ({Future<String?> future, DateTime at})>{};
  static const _ttl = Duration(seconds: 30);
  static const _maxEntries = 8;

  /// 长按意图出现时调用:为 [topicId] 预取主贴 cooked。
  /// 同 id 在途/就绪的请求直接复用,不重复发起。
  static void preload(DiscourseService service, int topicId) {
    final existing = _entries[topicId];
    if (existing != null && DateTime.now().difference(existing.at) < _ttl) {
      return;
    }
    _evictOverflow();
    _entries[topicId] = (
      future: service.getTopicFirstPostCooked(topicId),
      at: DateTime.now(),
    );
  }

  /// 取走 [topicId] 的预加载 Future(一次性消费);无缓存或已过期返回 null
  static Future<String?>? take(int topicId) {
    final entry = _entries.remove(topicId);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) >= _ttl) return null;
    return entry.future;
  }

  static void _evictOverflow() {
    if (_entries.length < _maxEntries) return;
    final now = DateTime.now();
    _entries.removeWhere((_, e) => now.difference(e.at) >= _ttl);
    // LinkedHashMap 保持插入序,从头清最旧
    while (_entries.length >= _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}
