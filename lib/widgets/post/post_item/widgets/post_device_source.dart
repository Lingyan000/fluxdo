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
          style:
              TextButton.styleFrom(
                backgroundColor: Colors.transparent,
                overlayColor: Colors.transparent,
                splashFactory: NoSplash.splashFactory,
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                textStyle: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  height: 1.4,
                ),
                alignment: AlignmentDirectional.centerStart,
                padding: const EdgeInsets.symmetric(vertical: 4),
                minimumSize: const Size(44, 32),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ).copyWith(
                foregroundBuilder: (context, states, child) => AnimatedOpacity(
                  opacity: states.contains(WidgetState.pressed) ? 0.55 : 1,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 100),
                  child: child,
                ),
              ),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
