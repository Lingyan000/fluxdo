import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/sticker.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/cached_image.dart';

/// 表情包分组图标(市场卡片、分组预览页共用)。
///
/// 图标可能是图片地址、单个 emoji 或空;图片未就绪/失败时显示分组名首字。
class StickerGroupIcon extends StatelessWidget {
  const StickerGroupIcon({
    super.key,
    required this.group,
    this.priority = DownloadPriority.normal,
  });

  static const double size = 40;

  final StickerGroup group;
  final DownloadPriority priority;

  @override
  Widget build(BuildContext context) {
    final icon = group.icon;
    if (icon.startsWith('http://') || icon.startsWith('https://')) {
      return ClipRSuperellipse(
        borderRadius: context.shapes.borderRadius(8),
        child: RepaintBoundary(
          child: CachedImage(
            url: icon,
            width: size,
            height: size,
            memCacheWidth: 80,
            memCacheHeight: 80,
            thumbnailMode: true,
            priority: priority,
            fit: BoxFit.cover,
            bucket: BlobImageCache.stickerOriginalBucket,
            placeholder: _buildFallback,
            errorBuilder: (context, _, _) => _buildFallback(context),
          ),
        ),
      );
    }

    if (icon.isNotEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: Text(icon, style: const TextStyle(fontSize: 24))),
      );
    }

    return _buildFallback(context);
  }

  Widget _buildFallback(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(8),
        ),
      ),
      child: Center(
        child: Text(
          // characters.first:名字以 emoji 开头时 name[0] 会切开代理对
          group.name.isNotEmpty ? group.name.characters.first : '?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
