/// 底栏拖动定位的位移映射：手指横向位移 → 目标楼层（stream 索引，1 起）。
///
/// 两段式：
/// - 步进段：起手 [stepCount] × [stepWidth] 内逐楼移动，短拖即「上一楼 /
///   下一楼」，每跨一楼由调用方给一次轻触觉；
/// - 加速段：超出步进段后按比例推进，系数由「该方向剩余楼数 ÷ 手指到
///   手势面边缘的剩余距离」实时推导，拖到边缘恰好到达首楼或末楼 ——
///   长话题不需要额外的精细模式，也不依赖写死的倍率。
///
/// 向右为往后读（与进度线填充方向一致）。
int topicScrubTargetIndex({
  required int startIndex,
  required int totalCount,
  required double startX,
  required double currentX,
  required double surfaceLeft,
  required double surfaceRight,
  double stepWidth = 24,
  int stepCount = 3,
}) {
  if (totalCount <= 1) return 1;
  final start = startIndex.clamp(1, totalCount);
  final dx = currentX - startX;
  if (dx == 0) return start;

  final forward = dx > 0;
  final distance = dx.abs();
  final stepZone = stepWidth * stepCount;
  final steps = (distance / stepWidth).floor().clamp(0, stepCount);

  int offset;
  if (distance <= stepZone) {
    offset = steps;
  } else {
    final remainingFloors = forward
        ? totalCount - start - stepCount
        : start - 1 - stepCount;
    if (remainingFloors <= 0) {
      offset = steps;
    } else {
      final remainingPx =
          (forward ? surfaceRight - startX : startX - surfaceLeft) - stepZone;
      final ratio = remainingPx <= 0
          ? 1.0
          : ((distance - stepZone) / remainingPx).clamp(0.0, 1.0);
      offset = stepCount + (ratio * remainingFloors).round();
    }
  }

  final target = forward ? start + offset : start - offset;
  return target.clamp(1, totalCount);
}
