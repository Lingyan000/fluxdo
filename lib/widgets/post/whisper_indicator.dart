import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';

/// 悄悄话（Whisper）指示器组件
/// 用于标识仅管理员/版主可见的帖子
class WhisperIndicator extends StatelessWidget {
  const WhisperIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: ShapeDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3),
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(12),
          side: BorderSide(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.visibility_off_rounded,
            size: 12,
            color: theme.colorScheme.tertiary,
          ),
          const SizedBox(width: 4),
          Text(
            context.l10n.post_whisperIndicator,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.tertiary,
              fontWeight: FontWeight.w500,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}
