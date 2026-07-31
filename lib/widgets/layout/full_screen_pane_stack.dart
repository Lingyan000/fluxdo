import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/selected_topic_provider.dart';

typedef FullScreenPaneBuilder =
    Widget Function(BuildContext context, PaneEntry entry, VoidCallback onBack);

/// 单栏模式下承载平行视界栈顶内容，并保持与双栏模式一致的返回语义。
class FullScreenPaneStack extends ConsumerWidget {
  const FullScreenPaneStack({
    super.key,
    required this.stackProvider,
    required this.builder,
  });

  final SelectedTopicProvider stackProvider;
  final FullScreenPaneBuilder builder;

  void _handleBack(BuildContext context, WidgetRef ref) {
    final selected = ref.read(stackProvider);
    if (selected.isStacked) {
      ref.read(stackProvider.notifier).pop();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(stackProvider);
    final entry = selected.topEntry;
    if (entry == null) return const SizedBox.shrink();

    return PopScope(
      canPop: !selected.isStacked,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(stackProvider.notifier).clear();
          return;
        }
        _handleBack(context, ref);
      },
      child: builder(context, entry, () => _handleBack(context, ref)),
    );
  }
}
