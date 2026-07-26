import 'package:flutter/widgets.dart';

import 'utils.dart';

/// 双击缩放动画的驱动目标。
///
/// 动画本体由手势层持有并驱动(与其他动画同受指针打断管理,避免
/// mixin 侧 controller 在新手势开始后继续回灌、清掉拖拽会话锚点);
/// 主工程 mixin 只负责算目标倍率后调用 [animateDoubleTapZoom]。
abstract class DoubleTapTarget {
  Offset? get pointerDownPosition;
  GestureDetails? get gestureDetails;
  void handleDoubleTap({double? scale, Offset? doubleTapPosition});

  /// 弹簧动画缩放到 [targetScale](快起慢收,可被新手势无缝打断)
  void animateDoubleTapZoom({
    required double targetScale,
    Offset? doubleTapPosition,
  });
}

/// GesturePageView 的仲裁对象:翻页手势需要读取当前图片的手势状态
/// (能否让渡拖拽给翻页)并在滚动中广播 scale 事件。
abstract class GesturePageViewArbiter {
  GestureDetails? get gestureDetails;
  set gestureDetails(GestureDetails? value);
  bool get mounted;
  void handleScaleStart(ScaleStartDetails details);
  void handleScaleUpdate(ScaleUpdateDetails details);
  void handleScaleEnd(ScaleEndDetails details);
}

/// 图片手势状态控制器 —— 查看器会话级的单一真相。
///
/// 缩放/平移([details])与下滑关闭位移([slideOffset]/[slideScale])
/// 从 Widget State 外提到此对象,生命周期由页面持有:loading→completed
/// 等树切换只更换绘制载体,状态与进行中的交互不再随载体销毁。
///
/// 消费方:
/// - RenderRawGestureImage 监听并在每次通知时 markNeedsPaint(绘制);
/// - GestureSurface 写入手势结果、按 slide 状态构建位移变换(交互);
/// - ExtendedImageSlidePageState 在滑动/回弹每 tick 调 [updateSlide]。
class ImageGestureController extends ChangeNotifier {
  ImageGestureController({GestureConfig? config})
    : _config = config ?? GestureConfig() {
    _details = GestureDetails(
      totalScale: _config.initialScale,
      offset: Offset.zero,
      initialAlignment: _config.initialAlignment,
    );
  }

  GestureConfig _config;
  GestureConfig get config => _config;
  set config(GestureConfig value) {
    final bool needReset =
        _config.initialScale != value.initialScale ||
        _config.initialAlignment != value.initialAlignment;
    _config = value;
    if (needReset) {
      reset();
    }
  }

  GestureDetails? _details;
  GestureDetails? get details => _details;
  set details(GestureDetails? value) {
    _details = value;
    _config.gestureDetailsIsChanged?.call(value);
    notifyListeners();
  }

  Offset _slideOffset = Offset.zero;

  /// 下滑关闭当前位移(SlidePageState 每 tick 同步)
  Offset get slideOffset => _slideOffset;

  double _slideScale = 1.0;

  /// 下滑关闭当前缩放
  double get slideScale => _slideScale;

  /// SlidePageState 滑动/回弹每 tick 同步位移与缩放
  /// (替代旧的「每 tick 通知载体 State setState」驱动回环)。
  void updateSlide(Offset offset, double scale) {
    _slideOffset = offset;
    _slideScale = scale;
    // 与旧载体 slide() 行为一致:slidePageOffset 参与 paint 时的
    // 反向平移,保证图片随 Transform 位移而 clip 区域钉在视口上
    _details?.slidePageOffset = offset;
    notifyListeners();
  }

  /// 重置回初始状态(如画廊翻页离场时,与旧行为「离页即重置缩放」一致)
  void reset() {
    _slideOffset = Offset.zero;
    _slideScale = 1.0;
    details = GestureDetails(
      totalScale: _config.initialScale,
      offset: Offset.zero,
      initialAlignment: _config.initialAlignment,
    );
  }
}
