import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import 'metaverse_widget_library.dart';

/// 市场、安装选择和管理列表共用插件身份与简介的展示层级。
class MetaversePluginTile extends StatelessWidget {
  const MetaversePluginTile({
    super.key,
    required this.name,
    required this.icon,
    required this.metadata,
    required this.onTap,
    this.description,
    this.trailing,
  });

  final String name;
  final String? icon;
  final String metadata;
  final String? description;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      titleAlignment: ListTileTitleAlignment.top,
      leading: Container(
        width: 44,
        height: 44,
        decoration: ShapeDecoration(
          color: PageBackgroundScope.contentColor(
            context,
            theme.colorScheme.surfaceContainerHighest,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: context.shapes.borderRadius(12),
          ),
        ),
        child: Icon(metaversePluginIcon(icon), color: context.emphasis.accent),
      ),
      title: Text(name, style: theme.textTheme.titleMedium),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (description case final description? when description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            Text(
              metadata,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
