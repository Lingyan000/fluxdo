import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';
import '../../../../utils/dialog_utils.dart';

/// 帖子来源独立占行，避免与用户名、头衔和操作按钮争用宽度。
class PostDeviceSource extends StatelessWidget {
  const PostDeviceSource({super.key, required this.deviceName});

  final String? deviceName;

  @override
  Widget build(BuildContext context) {
    final device = deviceName?.trim();
    if (device == null || device.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final label = context.l10n.post_deviceSource(device);

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Tooltip(
        message: label,
        child: TextButton(
          onPressed: () => showAppDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(context.l10n.post_deviceSourceTitle),
              content: SingleChildScrollView(child: SelectableText(label)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.common_close),
                ),
              ],
            ),
          ),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurfaceVariant,
            textStyle: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              height: 1.4,
            ),
            alignment: AlignmentDirectional.centerStart,
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
