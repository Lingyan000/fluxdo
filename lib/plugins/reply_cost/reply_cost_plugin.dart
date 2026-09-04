import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';
import '../plugin_context.dart';
import '../site_plugin.dart';

/// 回复扣积分插件（对齐 linux.do 的 `discourse-reply-cost`）
///
/// 服务端在话题详情里下发 `reply_cost` 字段（抽奖等标签下的话题会设置正数）。
/// 网页端行为见插件产物 `discourse-reply-cost_main.js` 的 `reply-cost-confirm`
/// initializer：
///
/// ```js
/// api.composerBeforeSave(function () {
///   const cost = this?.topic?.reply_cost;
///   if (this.editingPost || !cost || cost <= 0) return Promise.resolve();
///   return dialog.yesNoConfirm({ message: i18n("reply_cost.confirm", { cost }) })
///     .then((ok) => { if (!ok) return Promise.reject(); });
/// });
/// ```
///
/// 即：编辑帖子不拦截，`reply_cost` 缺失或非正数不拦截，其余情况弹确认框，
/// 用户否认则中止提交。扣分本身由服务端完成，客户端只负责告知与确认。
class ReplyCostPlugin extends SitePlugin {
  const ReplyCostPlugin();

  /// 话题详情里的扣费字段名
  static const String costField = 'reply_cost';

  @override
  String get id => 'discourse-reply-cost';

  @override
  Future<bool> beforeReplySubmit(ReplySubmitContext context) async {
    // 对齐 `this.editingPost`：编辑已有帖子不扣费
    if (context.isEditing) return true;

    final cost = context.topic.readInt(costField);
    // 对齐 `!cost || cost <= 0`
    if (cost == null || cost <= 0) return true;

    final confirmed = await showAppDialog<bool>(
      context: context.context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.common_hint),
        content: Text(dialogContext.l10n.replyCost_confirm(cost)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.common_confirm),
          ),
        ],
      ),
    );

    // 点遮罩关闭返回 null，与「取消」同样视为中止
    return confirmed ?? false;
  }
}
