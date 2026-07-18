import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 话题卡片头像布局
enum TopicCardAvatarLayout {
  /// 头像在底部元信息行内(现状,32px)
  inline,

  /// 头像独占卡片左侧一列(40px,标题/摘要/元信息都在右侧)
  column,
}

/// 话题卡片自定义样式:元信息可精简字段开关 + 头像布局 + 动态头像开关。
/// 卡片骨架(分类/标题/时间/未读状态/头像)恒定显示,不提供开关 ——
/// 保证任意配置组合下卡片形态完整;可精简的只有作者名/标签/统计。
/// 仅作用于普通话题卡;私信卡(messageStyle)与置顶紧凑卡不受影响。
@immutable
class TopicCardStyle {
  final bool showAuthor;
  final bool showTags;
  final bool showReplies;
  final bool showLikes;
  final bool showViews;
  final TopicCardAvatarLayout avatarLayout;

  /// 标题字号(sp)。默认 15 = 现状;范围由设置页滑块约束(13~18)
  final double titleFontSize;

  /// 关闭后话题卡头像强制静态(不下载/播放 gif 等动图),其他页面不受影响
  final bool animatedAvatar;

  const TopicCardStyle({
    this.showAuthor = true,
    this.showTags = true,
    this.showReplies = true,
    this.showLikes = true,
    this.showViews = true,
    this.avatarLayout = TopicCardAvatarLayout.inline,
    this.titleFontSize = 15.0,
    this.animatedAvatar = true,
  });

  static const TopicCardStyle defaults = TopicCardStyle();

  bool get isDefault => this == defaults;

  TopicCardStyle copyWith({
    bool? showAuthor,
    bool? showTags,
    bool? showReplies,
    bool? showLikes,
    bool? showViews,
    TopicCardAvatarLayout? avatarLayout,
    double? titleFontSize,
    bool? animatedAvatar,
  }) {
    return TopicCardStyle(
      showAuthor: showAuthor ?? this.showAuthor,
      showTags: showTags ?? this.showTags,
      showReplies: showReplies ?? this.showReplies,
      showLikes: showLikes ?? this.showLikes,
      showViews: showViews ?? this.showViews,
      avatarLayout: avatarLayout ?? this.avatarLayout,
      titleFontSize: titleFontSize ?? this.titleFontSize,
      animatedAvatar: animatedAvatar ?? this.animatedAvatar,
    );
  }

  /// 解析持久化 JSON;缺键取默认值(向后兼容),解析失败返回 defaults
  factory TopicCardStyle.fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return defaults;
      return TopicCardStyle(
        showAuthor: json['showAuthor'] as bool? ?? true,
        showTags: json['showTags'] as bool? ?? true,
        showReplies: json['showReplies'] as bool? ?? true,
        showLikes: json['showLikes'] as bool? ?? true,
        showViews: json['showViews'] as bool? ?? true,
        avatarLayout: json['avatarLayout'] == 'column'
            ? TopicCardAvatarLayout.column
            : TopicCardAvatarLayout.inline,
        titleFontSize:
            ((json['titleFontSize'] as num?)?.toDouble() ?? 15.0)
                .clamp(13.0, 18.0),
        animatedAvatar: json['animatedAvatar'] as bool? ?? true,
      );
    } catch (_) {
      return defaults;
    }
  }

  String toJsonString() => jsonEncode({
    'showAuthor': showAuthor,
    'showTags': showTags,
    'showReplies': showReplies,
    'showLikes': showLikes,
    'showViews': showViews,
    'avatarLayout': avatarLayout.name,
    'titleFontSize': titleFontSize,
    'animatedAvatar': animatedAvatar,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TopicCardStyle &&
        other.showAuthor == showAuthor &&
        other.showTags == showTags &&
        other.showReplies == showReplies &&
        other.showLikes == showLikes &&
        other.showViews == showViews &&
        other.avatarLayout == avatarLayout &&
        other.titleFontSize == titleFontSize &&
        other.animatedAvatar == animatedAvatar;
  }

  @override
  int get hashCode => Object.hash(
    showAuthor,
    showTags,
    showReplies,
    showLikes,
    showViews,
    avatarLayout,
    titleFontSize,
    animatedAvatar,
  );
}

/// 话题卡样式全局快照:preferencesProvider 是唯一写入方。
/// 排版层(TopicCardLayout)与 widget 卡直读,免逐调用点透传;
/// UI 响应性不靠它 —— 列表页 ref.watch(select) 触发 rebuild,
/// rebuild 中 obtain 读到新值 + stamp 变化换新实例。
abstract final class TopicCardStyleScope {
  static TopicCardStyle current = TopicCardStyle.defaults;
}
