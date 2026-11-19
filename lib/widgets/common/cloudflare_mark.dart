import 'package:common_ui/common_ui.dart';
import 'package:flutter/widgets.dart';

/// Cloudflare 云朵标志（官方双色：主云 #F38020、后云 #FAAE40）
///
/// 路径取自 Simple Icons（CC0），原为单色单路径，这里拆成前后两朵云
/// 分别上色。用于提示"正在进行 Cloudflare 安全验证"。
class CloudflareMark extends StatelessWidget {
  final double width;

  const CloudflareMark({super.key, this.width = 24});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width * 10.86 / 24,
      child: const AppSvgAsset('assets/icons/cloudflare.svg'),
    );
  }
}
