import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 话题会话状态（仅在当前会话有效）
/// 用于记录本次阅读过程中哪些帖子被标记为已读（通过 Timings 上报）
class TopicSessionState {
  /// 本次会话中已读的帖子编号集合
  final Set<int> readPostNumbers;

  /// 话题标题（用于基于话题的私信预填标题等）
  final String? topicTitle;

  /// 帖级临时关闭弹幕的帖子 id(全局弹幕偏好开启时的单帖覆盖)。
  /// 下沉到会话层:短帖 PostItem 与长帖 header/chunk/footer 是不同
  /// widget,State 级开关无法共享,且随 sliver 回收丢失。
  final Set<int> danmakuOffPostIds;

  const TopicSessionState({
    this.readPostNumbers = const {},
    this.topicTitle,
    this.danmakuOffPostIds = const {},
  });

  TopicSessionState copyWith({
    Set<int>? readPostNumbers,
    String? topicTitle,
    Set<int>? danmakuOffPostIds,
  }) {
    return TopicSessionState(
      readPostNumbers: readPostNumbers ?? this.readPostNumbers,
      topicTitle: topicTitle ?? this.topicTitle,
      danmakuOffPostIds: danmakuOffPostIds ?? this.danmakuOffPostIds,
    );
  }
}

class TopicSessionNotifier extends Notifier<TopicSessionState> {
  final int topicId;

  TopicSessionNotifier(this.topicId);

  @override
  TopicSessionState build() {
    return const TopicSessionState();
  }

  /// 标记帖子为已读（添加到已读集合）
  void markAsRead(Set<int> postNumbers) {
    if (postNumbers.isEmpty) return;

    final newRead = {...state.readPostNumbers, ...postNumbers};
    if (newRead.length != state.readPostNumbers.length) {
      state = state.copyWith(readPostNumbers: newRead);
    }
  }

  /// 记录话题标题（详情加载后调用）
  void setTopicTitle(String? title) {
    if (title == null || title.isEmpty || state.topicTitle == title) return;
    state = state.copyWith(topicTitle: title);
  }

  /// 帖级临时弹幕开关(off=true 表示该帖临时关闭弹幕、回退列表展示)
  void setDanmakuOff(int postId, bool off) {
    final current = state.danmakuOffPostIds;
    if (off == current.contains(postId)) return;
    final updated = {...current};
    if (off) {
      updated.add(postId);
    } else {
      updated.remove(postId);
    }
    state = state.copyWith(danmakuOffPostIds: updated);
  }
}

/// 话题会话状态 Provider
/// family 参数为 topicId
final topicSessionProvider = NotifierProvider.family<TopicSessionNotifier, TopicSessionState, int>(
  TopicSessionNotifier.new,
);
