import 'dart:math' as math;

bool isComposerDockedKeyboardHeight(double height) => height >= 200;

/// 自定义面板与正常软键盘等高；浮动/外接键盘的底部栏高度不可用作面板高度。
///
/// 插件也会缓存这些非零小高度。低于 200 的回报不足以容纳表情内容和
/// 底部切换栏，按未获得可用键盘高度处理，恢复宿主指定的默认高度。
double resolveComposerPanelHeight({
  required double keyboardHeight,
  required double fallbackHeight,
  required double safeBottom,
}) => math.max(
  isComposerDockedKeyboardHeight(keyboardHeight)
      ? keyboardHeight
      : fallbackHeight,
  safeBottom,
);
