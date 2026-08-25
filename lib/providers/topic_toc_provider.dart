// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_provider.dart';

/// 话题目录(TOC)面板展开状态 —— 三态:
/// - `null`(从未手动切换):自动,由页面按可用宽度决定(够宽才默认展开,
///   避免遮挡正文);
/// - `true`/`false`:用户显式展开/收起的持久化选择,优先于自动规则。
final topicTocVisibilityProvider =
    StateNotifierProvider<TopicTocVisibilityNotifier, bool?>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return TopicTocVisibilityNotifier(prefs);
});

class TopicTocVisibilityNotifier extends StateNotifier<bool?> {
  static const String _key = 'topic_toc_visible';
  final SharedPreferences _prefs;

  TopicTocVisibilityNotifier(this._prefs) : super(_prefs.getBool(_key));

  /// 手动切换:[currentResolved] 是当前生效值(自动态下为页面按宽度
  /// 解析的结果),翻转后固化为显式选择。
  void toggle(bool currentResolved) {
    final next = !currentResolved;
    state = next;
    _prefs.setBool(_key, next);
  }
}
