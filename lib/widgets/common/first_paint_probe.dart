import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 首帧 paint 探针:child 第一次真正被绘制时回调一次。
///
/// 用途 = **零成本的"在视口内"判定**:sliver cacheExtent 预建区的
/// widget 会 build/layout,但 paint 只发生在真视口内 —— 首帧 paint
/// 即"用户看得见",用来把该图的下载请求 bump 到高优先级队列
/// (Telegram ImageReceiver 滚入视野 bumpPriority 的同款语义),
/// 不需要 visibility_detector 之类的持续跟踪设施。
class FirstPaintProbe extends SingleChildRenderObjectWidget {
  const FirstPaintProbe({super.key, required this.onFirstPaint, super.child});

  final VoidCallback onFirstPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstPaintProbe(onFirstPaint);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderFirstPaintProbe).onFirstPaint = onFirstPaint;
  }
}

class _RenderFirstPaintProbe extends RenderProxyBox {
  _RenderFirstPaintProbe(this.onFirstPaint);

  VoidCallback onFirstPaint;
  bool _fired = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_fired) {
      _fired = true;
      onFirstPaint();
    }
    super.paint(context, offset);
  }
}
