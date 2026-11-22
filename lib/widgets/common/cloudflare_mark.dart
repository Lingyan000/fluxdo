import 'package:common_ui/common_ui.dart';
import 'package:flutter/widgets.dart';

/// Cloudflare 云朵标志（官方双色：主云 #F38020、后云 #FAAE40）
///
/// 路径取自 Simple Icons（CC0），原为单色单路径，这里拆成前后两朵云
/// 分别上色。用于提示"正在进行 Cloudflare 安全验证"。
class CloudflareMark extends StatelessWidget {
  const CloudflareMark({super.key, this.width = 24}) : _asIcon = false;

  /// 设置项使用同一轮廓，尺寸和前景色取自所在位置的图标主题。
  const CloudflareMark.icon({super.key}) : width = 24, _asIcon = true;

  final double width;
  final bool _asIcon;

  @override
  Widget build(BuildContext context) {
    final icons = _asIcon ? IconTheme.of(context) : null;
    final size = icons?.size ?? width;
    final mark = SizedBox(
      width: size,
      height: size * 10.86 / 24,
      child: AppSvgAsset('assets/icons/cloudflare.svg', tint: icons?.color),
    );
    return _asIcon
        ? SizedBox.square(
            dimension: size,
            child: Center(child: mark),
          )
        : mark;
  }
}
