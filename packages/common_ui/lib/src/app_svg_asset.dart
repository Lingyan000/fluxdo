import 'package:flutter/widgets.dart';
import 'package:jovial_svg/jovial_svg.dart';

/// 显示构建时转换为 SI 的内置 SVG，资源键沿用源文件路径。
class AppSvgAsset extends StatelessWidget {
  const AppSvgAsset(this.assetName, {super.key, this.tint});

  final String assetName;
  final Color? tint;

  // 列表项移出视口后仍可复用最近解码的图标。着色由外层处理，共享原图。
  static final _cache = ScalableImageCache(size: 32);

  @override
  Widget build(BuildContext context) {
    final image = ScalableImageWidget.fromSISource(
      si: ScalableImageSource.fromSI(DefaultAssetBundle.of(context), assetName),
      cache: _cache,
    );
    final color = tint;
    return color == null
        ? image
        : ColorFiltered(
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            child: image,
          );
  }
}
