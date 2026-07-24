import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import 'package:m3e_ui/m3e_ui.dart';

class PagedListFooter extends StatelessWidget {
  const PagedListFooter({
    super.key,
    required this.hasMore,
    required this.isLoadingMore,
    required this.isLoadMoreFailed,
    required this.onRetry,
    this.padding = const EdgeInsets.all(16),
  });

  final bool hasMore;
  final bool isLoadingMore;
  final bool isLoadMoreFailed;
  final VoidCallback onRetry;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (isLoadMoreFailed) {
      child = GestureDetector(
        onTap: onRetry,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.refresh_rounded,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              context.l10n.common_loadFailedTapRetry,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      );
    } else if (isLoadingMore) {
      child = const LoadingSpinner(size: 24);
    } else if (!hasMore) {
      child = Text(
        context.l10n.common_noMore,
        style: const TextStyle(color: Colors.grey),
      );
    } else {
      child = const SizedBox(height: 16);
    }

    return Padding(
      padding: padding,
      child: Center(child: child),
    );
  }
}
