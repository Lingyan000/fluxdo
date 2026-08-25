import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 高度上报:child 布局完把自身高度回传,只在高度真的变了时回调。
///
/// 用途 = 让**悬浮**在内容之上的条(聊天输入条等)把自己占的高度告诉
/// 底下的滚动区,好让列表留出等量的底部避让。悬浮布局里父级拿不到这个
/// 数(条不再是 Column 的兄弟节点),而条的高度一直在动 —— 附件预览行、
/// 回复上下文条、多行输入都会把它撑高。
///
/// 回调推到帧末:performLayout 里直接改 ValueNotifier / setState 会在
/// 同一帧内再次触发布局,Flutter 会断言炸掉。
class HeightReporter extends SingleChildRenderObjectWidget {
  const HeightReporter({super.key, required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderHeightReporter).onHeight = onHeight;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (_reported == height) return;
    _reported = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}
