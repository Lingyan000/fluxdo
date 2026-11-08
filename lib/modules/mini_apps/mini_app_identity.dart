import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import 'mini_app.dart';
import 'mini_app_icon.dart';

/// 菜单、授权和反馈操作共用应用身份，始终明确当前操作属于哪个应用。
class MiniAppIdentity extends StatelessWidget {
  const MiniAppIdentity({
    super.key,
    required this.app,
    this.subtitle,
    this.compact = false,
  });
  final MiniApp app;
  final String? subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary =
        subtitle ??
        [
          if (app.author.isNotEmpty) app.author,
          if (app.version.isNotEmpty) context.l10n.miniApp_version(app.version),
        ].join(' · ');
    return Row(
      children: [
        MiniAppIcon(app, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                app.name,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              if (secondary.isNotEmpty && !compact) ...[
                const SizedBox(height: 3),
                Text(
                  secondary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
