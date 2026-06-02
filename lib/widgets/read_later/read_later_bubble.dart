import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/read_later_provider.dart';
import '../floating_widget_mixin.dart';
import 'read_later_sheet.dart';

/// 稍后阅读浮窗气泡
class ReadLaterBubble extends ConsumerStatefulWidget {
  const ReadLaterBubble({super.key});

  @override
  ConsumerState<ReadLaterBubble> createState() => _ReadLaterBubbleState();
}

class _ReadLaterBubbleState extends ConsumerState<ReadLaterBubble>
    with TickerProviderStateMixin, FloatingWidgetMixin {
  static const double _bubbleSize = 48.0;

  bool _isSheetOpen = false;

  @override
  double get floatingOverlap => 16.0;

  @override
  double get floatingBottomMargin => 80.0;

  @override
  double get initialRelativeY => 0.7;

  @override
  void initState() {
    super.initState();
    initFloating();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateFloatingDependencies();
  }

  @override
  void dispose() {
    disposeFloating();
    super.dispose();
  }

  void _handleTap() async {
    setState(() => _isSheetOpen = true);
    await ReadLaterSheet.show();
    if (mounted) {
      setState(() => _isSheetOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appReady = ref.watch(appReadyProvider);
    final items = ref.watch(readLaterProvider);

    // 应用未就绪、列表为空、或面板已打开时不显示
    if (!appReady || items.isEmpty || _isSheetOpen) return const SizedBox.shrink();

    final pos = floatingPosition();
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = colorScheme.inverseSurface;
    final contentColor = colorScheme.onInverseSurface;

    return Positioned(
      left: pos.left,
      top: pos.top,
      right: pos.right,
      child: Opacity(
        opacity: floatingIsInitialized ? 1.0 : 0.0,
        child: GestureDetector(
          onPanStart: onFloatingPanStart,
          onPanUpdate: onFloatingPanUpdate,
          onPanEnd: onFloatingPanEnd,
          onTap: _handleTap,
          child: Container(
            width: _bubbleSize,
            height: _bubbleSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: backgroundColor.withValues(alpha: 0.9),
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.1),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 6,
                  spreadRadius: 1,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(
                    Icons.layers,
                    size: 22,
                    color: contentColor,
                  ),
                ),
                Positioned(
                  left: floatingIsRight ? -2 : null,
                  right: floatingIsRight ? null : -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: colorScheme.error,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    child: Center(
                      child: Text(
                        '${items.length}',
                        style: TextStyle(
                          color: colorScheme.onError,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
