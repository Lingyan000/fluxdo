import 'package:flutter/widgets.dart';

import 'plugin_context.dart';

/// 站点插件基类
///
/// 对应 Discourse 侧的社区自有插件（如 linux.do 的 `discourse-reply-cost`）。
/// 这些功能只在特定社区存在，不属于 Discourse 标准能力，因此不写进核心流程，
/// 而是由具体站点在 [SiteCustomization.plugins] 里声明启用。
///
/// 新增钩子时在此追加带默认实现的方法，已有插件无需改动。
abstract class SitePlugin {
  const SitePlugin();

  /// 插件标识，对齐 Discourse 插件名，例如 `discourse-reply-cost`
  String get id;

  /// 回复提交前钩子
  ///
  /// 对齐 Discourse 前端 `api.composerBeforeSave`：
  /// 返回 `true` 放行提交，返回 `false` 中止提交（如用户取消了确认框）。
  ///
  /// 默认放行。
  Future<bool> beforeReplySubmit(ReplySubmitContext context) async => true;

  /// 改写编辑器的最小正文字数
  ///
  /// 对齐 Discourse `api.registerValueTransformer("composer-minimum-post-length")`：
  /// [value] 是上一级算出的值(站点默认/会员优惠)，插件返回新值或原值。
  ///
  /// 默认不改写。
  int composerMinPostLength(int value, ComposerMinLengthContext context) =>
      value;

  /// 字数不足时追加在计数器后的警告文案
  ///
  /// 对齐主题组件 `CharacterCounts` 的 `showWarning`：仅正文计数器、
  /// 仅在未达下限时显示。返回 null 表示不追加。
  ///
  /// 传入 [context] 而不用全局 `S.current`：计数器可能渲染在主
  /// navigator 树以外（如弹层、测试环境），那时 `navigatorKey.currentContext`
  /// 为 null 会直接断言失败。
  String? composerCharCountWarning(BuildContext context) => null;
}
