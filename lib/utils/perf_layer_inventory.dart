import 'package:flutter/rendering.dart';

/// raster 大帧的图层清单:遍历当前 layer 树,分类计数 + 与上次快照
/// diff,回答"这帧到底提交了什么"。
///
/// 背景:raster 耗时发生在引擎 C++/GPU 侧,Dart 日志只有总数;历史上
/// raster 尖峰归因(字形图集/纹理上传/saveLayer)只能靠人工差分实验。
/// 这份清单把"资源清单"一步自动化:图片(PictureLayer 字节)、saveLayer
/// 源(Opacity/ImageFilter/Backdrop/ShaderMask/ColorFilter)、平台视图、
/// 外部纹理逐类点名,配合增量 diff,"这帧多了个 BackdropFilter"直接
/// 现形。引擎内部态(字形图集增长、shader 编译)仍照不到——清单排除
/// 资源型嫌疑后,再上 Perfetto/Instruments 才是对的顺序。
///
/// 注意:FrameTiming 回调异步于帧提交,遍历时 layer 树可能已经变化,
/// 清单是"当下树"的近似而非"那一帧"的精确快照——诊断精度可接受,
/// 读数时留意。全部走 public API(RenderObject.layer / firstChild /
/// nextSibling / Picture.approximateBytesUsed),release 可用。
class LayerInventory {
  LayerInventory._();

  static _Snapshot? _last;

  /// 采集一次清单并与上次采集 diff,返回单行摘要;树不可用时返回 null。
  /// 调用方自行节流(与 raster 大帧分支的 2s 节流合用)。
  static String? capture() {
    final snap = _Snapshot();
    var any = false;
    for (final renderView in RendererBinding.instance.renderViews) {
      // RenderObject.layer 标注 @protected(防业务代码误改图层),这里是
      // 只读诊断遍历,属于其注释明示的合法读取场景
      // ignore: invalid_use_of_protected_member
      final root = renderView.layer;
      if (root == null) continue;
      any = true;
      _visit(root, snap);
    }
    if (!any) return null;

    final prev = _last;
    _last = snap;
    return snap.summary(prev);
  }

  static void _visit(Layer layer, _Snapshot snap) {
    switch (layer) {
      case PictureLayer(:final picture):
        snap.pictures++;
        final bytes = picture?.approximateBytesUsed ?? 0;
        snap.pictureBytes += bytes;
        if (bytes > snap.maxPictureBytes) snap.maxPictureBytes = bytes;
      case OpacityLayer():
        snap.opacity++;
      case BackdropFilterLayer():
        snap.backdrop++;
      case ImageFilterLayer():
        snap.imageFilter++;
      case ShaderMaskLayer():
        snap.shaderMask++;
      case ColorFilterLayer():
        snap.colorFilter++;
      case PlatformViewLayer():
        snap.platformView++;
      case TextureLayer():
        snap.texture++;
      default:
        break;
    }
    if (layer is ContainerLayer) {
      var child = layer.firstChild;
      while (child != null) {
        _visit(child, snap);
        child = child.nextSibling;
      }
    }
  }
}

class _Snapshot {
  int pictures = 0;
  int pictureBytes = 0;
  int maxPictureBytes = 0;
  int opacity = 0;
  int backdrop = 0;
  int imageFilter = 0;
  int shaderMask = 0;
  int colorFilter = 0;
  int platformView = 0;
  int texture = 0;

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  String summary(_Snapshot? prev) {
    final parts = <String>[
      'pic $pictures(${_mb(pictureBytes)}MB,max${_mb(maxPictureBytes)})',
      if (opacity > 0) 'op $opacity',
      if (backdrop > 0) 'backdrop $backdrop',
      if (imageFilter > 0) 'imgFilter $imageFilter',
      if (shaderMask > 0) 'shaderMask $shaderMask',
      if (colorFilter > 0) 'colorFilter $colorFilter',
      if (platformView > 0) 'pv $platformView',
      if (texture > 0) 'tex $texture',
    ];
    var line = '图层: ${parts.join(' ')}';
    if (prev != null) {
      final deltas = <String>[
        if (pictures != prev.pictures)
          'pic${_sign(pictures - prev.pictures)}'
              '(${_sign2(pictureBytes - prev.pictureBytes)}MB)',
        if (opacity != prev.opacity) 'op${_sign(opacity - prev.opacity)}',
        if (backdrop != prev.backdrop)
          'backdrop${_sign(backdrop - prev.backdrop)}',
        if (imageFilter != prev.imageFilter)
          'imgFilter${_sign(imageFilter - prev.imageFilter)}',
        if (shaderMask != prev.shaderMask)
          'shaderMask${_sign(shaderMask - prev.shaderMask)}',
        if (colorFilter != prev.colorFilter)
          'colorFilter${_sign(colorFilter - prev.colorFilter)}',
        if (platformView != prev.platformView)
          'pv${_sign(platformView - prev.platformView)}',
        if (texture != prev.texture) 'tex${_sign(texture - prev.texture)}',
      ];
      if (deltas.isNotEmpty) {
        line += ' | Δ上次: ${deltas.join(' ')}';
      }
    }
    return line;
  }

  static String _sign(int v) => v >= 0 ? '+$v' : '$v';

  static String _sign2(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb >= 0 ? '+${mb.toStringAsFixed(1)}' : mb.toStringAsFixed(1);
  }
}
