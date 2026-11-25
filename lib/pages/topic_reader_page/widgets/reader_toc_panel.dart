import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/s.dart';
import '../reader_document.dart';
import '../reader_preferences.dart';

/// 首贴沉浸阅读目录面板：仅展示首贴的真实 HTML 原生标题树（`h1`–`h5`）。
class ReaderTocPanel extends StatelessWidget {
  const ReaderTocPanel({
    super.key,
    required this.headings,
    required this.palette,
    required this.activeHeadingId,
    required this.onSelectHeading,
    this.scrollController,
    this.onClose,
    this.isSidebar = false,
  });

  final List<ReaderHeading> headings;
  final ReaderPalette palette;
  final String? activeHeadingId;
  final ValueChanged<ReaderHeading> onSelectHeading;
  final ScrollController? scrollController;
  final VoidCallback? onClose;
  final bool isSidebar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isSidebar) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Icon(
                  Symbols.toc_rounded,
                  size: 20,
                  color: context.emphasis.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.reader_toc,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: palette.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    key: const ValueKey('reader_toc_sidebar_close'),
                    onPressed: onClose,
                    visualDensity: VisualDensity.compact,
                    tooltip: l10n.topicDetail_tocCollapse,
                    icon: const Icon(AppIcons.chevronLeft, size: 20),
                  ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 0.5,
            color: palette.outline.withValues(alpha: 0.5),
          ),
        ],
        Expanded(
          child: headings.isEmpty
              ? AppEmptyState(
                  icon: const Icon(Symbols.toc_rounded),
                  title: l10n.reader_emptyToc,
                )
              : _buildHeadingList(context),
        ),
      ],
    );
  }

  Widget _buildHeadingList(BuildContext context) {
    final theme = Theme.of(context);
    final minLevel = headings.fold<int>(
      5,
      (min, h) => h.level < min ? h.level : min,
    );

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      itemCount: headings.length,
      itemBuilder: (context, index) {
        final heading = headings[index];
        final isActive = heading.id == activeHeadingId;
        final depth = (heading.level - minLevel).clamp(0, 3);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Material(
            color: isActive
                ? context.emphasis.selected.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: context.shapes.borderRadius(10),
            child: InkWell(
              key: ValueKey('reader_toc_heading_${heading.id}'),
              borderRadius: context.shapes.borderRadius(10),
              onTap: () => onSelectHeading(heading),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12.0 + depth * 14.0,
                  9,
                  12,
                  9,
                ),
                child: Text(
                  heading.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isActive ? context.emphasis.selected : palette.ink,
                    fontWeight: isActive || depth == 0
                        ? FontWeight.w600
                        : FontWeight.w400,
                    fontSize: depth == 0 ? 14 : 13,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
