import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import '../../l10n/s.dart';
import '../../providers/topic_list/filter_provider.dart';

class TopicListUpdateBanner extends StatelessWidget {
  const TopicListUpdateBanner({
    super.key,
    required this.count,
    required this.filter,
    required this.newNewView,
    required this.loading,
    required this.onTap,
  });

  final int count;
  final TopicListFilter filter;
  final bool newNewView;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (filter) {
      TopicListFilter.unread => context.l10n.topics_viewUnreadTopics(count),
      TopicListFilter.newTopics when !newNewView =>
        context.l10n.topics_viewNewOnlyTopics(count),
      _ => context.l10n.topics_viewNewTopics(count),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: loading ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.arrow_upward_rounded,
                          size: 14,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: TextStyle(
                            color: colors.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
