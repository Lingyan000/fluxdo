import '../models/topic.dart';

/// 统一控制内容过滤后的提示层，过滤结果本身不受影响。
class BlockedContentInfoVisibility {
  BlockedContentInfoVisibility._();

  static bool shouldShowTopicHint({
    required bool enabled,
    required int hiddenCount,
  }) => enabled && hiddenCount > 0;

  static PostStreamGaps? visiblePostGaps({
    required bool enabled,
    required PostStreamGaps? gaps,
  }) => enabled ? gaps : null;
}
