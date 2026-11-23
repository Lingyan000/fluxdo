import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../controllers/topic_jump_history.dart';

/// 手机浮层和宽屏阅读栏共用的逐级返回入口。
class TopicReturnButton extends StatelessWidget {
  const TopicReturnButton({
    super.key,
    required this.history,
    required this.onReturn,
    required this.onClear,
  });

  final TopicJumpHistory history;
  final VoidCallback onReturn;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final target = history.target;
        if (target == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final radius = context.shapes.borderRadius(24);
        final label = context.l10n.topicDetail_returnToPost(target.postNumber);
        return Material(
          color: theme.colorScheme.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: radius),
          elevation: 2,
          clipBehavior: Clip.antiAlias,
          child: IconTheme(
            data: IconThemeData(
              color: theme.colorScheme.onSecondaryContainer,
              size: 18,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: TextButton(
                    onPressed: history.returning ? null : onReturn,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSecondaryContainer,
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.only(left: 16, right: 8),
                      shape: RoundedRectangleBorder(borderRadius: radius),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (history.returning)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: LoadingSpinner(size: 18),
                          )
                        else
                          const Icon(Symbols.undo_rounded),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(label, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onClear,
                  tooltip: context.l10n.topicDetail_clearReturnHistory,
                  icon: const Icon(Symbols.close_rounded),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
