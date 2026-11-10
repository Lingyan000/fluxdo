import 'package:common_ui/common_ui.dart' show UiShapes;
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderShapes;

/// 圆角风格预设。
///
/// 主题可在 JSON 里用 `shape` 推荐一档（纸质偏适中、终端偏方正），
/// 用户也可以在外观设置里指定，覆盖主题的推荐。
enum ShapePreset {
  /// 标准：设计稿圆角，一直以来的默认外观。
  standard(UiShapes.standard),

  /// 适中：圆角收小。
  compact(UiShapes(scale: 0.6)),

  /// 方正：接近直角，胶囊按钮也收成小圆角。
  sharp(UiShapes(scale: 0.2, max: 3));

  const ShapePreset(this.shapes);

  /// 该档对应的形状 token。
  final UiShapes shapes;
}

extension UiShapesRender on UiShapes {
  /// 注入渲染引擎的同一形状风格。
  FluxdoRenderShapes get render => FluxdoRenderShapes(scale: scale, max: max);
}
