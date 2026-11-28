part of 'metaverse_widget_library.dart';

/// 元信息和任意详情插槽都获得有限宽度，窄屏按实际排版空间换行。
class _PluginRowMetadata extends StatelessWidget {
  const _PluginRowMetadata({required this.meta, this.detail});
  final String meta;
  final Widget? detail;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final label = Text(
        meta,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
      if (detail == null) return label;
      if (meta.isEmpty) return detail!;
      // 以文字缩放后的阅读宽度决定是否分行，不以设备类型判断。
      if (box.maxWidth / MediaQuery.textScalerOf(context).scale(1) < 240) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [label, const SizedBox(height: 2), detail!],
        );
      }
      return Row(
        children: [
          Expanded(child: label),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * .45),
            child: detail!,
          ),
        ],
      );
    },
  );
}
