import 'package:flutter/widgets.dart';

/// 话题级插件扩展字段的进程内缓存
///
/// 站点插件（如 linux.do 回复扣积分）关心的字段挂在**话题**上，而回复入口
/// 分散在帖子列表、楼中楼、划词引用等多处深层 widget 里。若把字段当作
/// 参数逐层透传，需要改动整条 post_item 组件链，代价与收益不成正比。
///
/// 这里改为在话题详情加载完成时按 topicId 记录一次，各回复入口按 id 取用。
/// 数据只在会话内有效，随话题详情刷新覆盖，[forget] 用于话题页销毁时清理。
class TopicPluginData {
  TopicPluginData._();

  static final Map<int, Map<String, dynamic>> _extras = {};

  /// 话题详情加载/刷新后写入扩展字段
  static void put(int topicId, Map<String, dynamic> extras) {
    if (extras.isEmpty) {
      _extras.remove(topicId);
      return;
    }
    _extras[topicId] = extras;
  }

  /// 读取扩展字段，未知话题返回空 Map
  static Map<String, dynamic> of(int? topicId) {
    if (topicId == null) return const <String, dynamic>{};
    return _extras[topicId] ?? const <String, dynamic>{};
  }

  /// 话题页销毁时清理
  static void forget(int topicId) => _extras.remove(topicId);

  @visibleForTesting
  static void clear() => _extras.clear();
}
