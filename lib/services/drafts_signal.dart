import 'package:flutter/foundation.dart';

/// 草稿变更信号。
///
/// 草稿列表需要在**发送**或**舍弃**之后自动去掉那一条,但这两件事都不
/// 发生在草稿页里(发送在回复框、舍弃也在回复框),页面自己无从知晓。
///
/// 服务层的 `deleteDraft` 恰好是两者的**唯一出口**(reply_sheet 发送成功
/// 与主动舍弃都调它),所以在那里 bump 一次,草稿页监听即可 —— 不用轮询,
/// 也不用给每条发帖路径都挂回调。
class DraftsSignal {
  DraftsSignal._();

  /// 每次草稿被删除(发送/舍弃)自增。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void notifyChanged() => revision.value++;
}
