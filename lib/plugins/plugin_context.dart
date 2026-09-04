import 'package:flutter/widgets.dart';

/// 插件钩子执行时可见的话题上下文
///
/// 插件多为社区侧非标准功能（Discourse 第三方插件序列化出的额外字段），
/// 核心模型不为其增加字段，改由这里携带原始 JSON 供插件自行解析。
@immutable
class TopicPluginContext {
  /// 话题 ID
  final int? topicId;

  /// 话题详情接口返回的原始 JSON（`/t/{id}.json` 顶层对象）
  ///
  /// 插件从中读取自己关心的非标准字段，例如 linux.do 的 `reply_cost`。
  final Map<String, dynamic> topicJson;

  const TopicPluginContext({
    this.topicId,
    this.topicJson = const <String, dynamic>{},
  });

  /// 读取原始 JSON 中的整数字段（兼容服务端返回字符串数字的情况）
  int? readInt(String key) {
    final value = topicJson[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// 读取原始 JSON 中的字符串字段
  String? readString(String key) {
    final value = topicJson[key];
    if (value is String) return value;
    return value?.toString();
  }

  /// 读取原始 JSON 中的布尔字段
  bool? readBool(String key) {
    final value = topicJson[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      if (value == 'true') return true;
      if (value == 'false') return false;
    }
    return null;
  }
}

/// 编辑器最小正文字数钩子的入参
///
/// 对齐 Discourse `composer-minimum-post-length` value transformer 的
/// `context.composer`。
@immutable
class ComposerMinLengthContext {
  /// 当前分类的 `custom_fields`(见 [Category.pluginExtras])
  final Map<String, dynamic> categoryExtras;

  /// 是否为话题首帖(新建话题/编辑一楼)
  final bool isFirstPost;

  /// 是否为私信
  final bool isPrivateMessage;

  /// 是否为与非真人用户的私信
  final bool isPmWithNonHumanUser;

  /// 站点 `max_post_length`,用于给插件抬高的下限封顶
  final int maxPostLength;

  const ComposerMinLengthContext({
    this.categoryExtras = const <String, dynamic>{},
    required this.isFirstPost,
    required this.isPrivateMessage,
    required this.isPmWithNonHumanUser,
    required this.maxPostLength,
  });

  /// 读取分类扩展字段里的整数(兼容字符串数字)
  ///
  /// 对齐 JS 的 `parseInt(x, 10) || 0`：解析失败一律当 0。
  int readCategoryInt(String key) {
    final value = categoryExtras[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

/// 回复提交前的钩子入参
///
/// 对齐 Discourse 前端 `composerBeforeSave`：编辑已有帖子时不触发拦截，
/// 因此这里显式携带 [isEditing] 供插件判断。
@immutable
class ReplySubmitContext {
  /// 弹出确认等 UI 所需的上下文（调用方保证调用时仍 mounted）
  final BuildContext context;

  /// 话题上下文
  final TopicPluginContext topic;

  /// 是否为编辑已有帖子
  final bool isEditing;

  /// 是否为私信
  final bool isPrivateMessage;

  const ReplySubmitContext({
    required this.context,
    required this.topic,
    required this.isEditing,
    required this.isPrivateMessage,
  });
}
