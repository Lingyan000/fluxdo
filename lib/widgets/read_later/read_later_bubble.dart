import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/read_later_provider.dart';
import '../floating_widget_mixin.dart';
import 'read_later_overlay.dart';

/// 稍后阅读浮窗气泡
class ReadLaterBubble extends ConsumerStatefulWidget {
  const ReadLaterBubble({super.key});

  @override
  ConsumerState<ReadLaterBubble> createState() => _ReadLaterBubbleState();
}

class _ReadLaterBubbleState extends ConsumerState<ReadLaterBubble>
    with TickerProviderStateMixin, FloatingWidgetMixin {
  static const double _bubbleSize = 48.0;

  bool _isOverlayOpen = false;
  bool _isPressed = false;

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
    setState(() => _isOverlayOpen = true);
    await ReadLaterOverlay.show();
    if (mounted) {
      setState(() => _isOverlayOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appReady = ref.watch(appReadyProvider);
    final items = ref.watch(readLaterProvider);

    // 应用未就绪或列表为空时彻底移除;打开浮层期间保留组件,
    // 用缩放动画隐藏/恢复,与浮层入退场衔接
    if (!appReady || items.isEmpty) return const SizedBox.shrink();

    final pos = floatingPosition();
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = colorScheme.inverseSurface;
    final contentColor = colorScheme.onInverseSurface;
    final visible = floatingIsInitialized && !_isOverlayOpen;

    return Positioned(
      left: pos.left,
      top: pos.top,
      right: pos.right,
      // 浮球挂在 MaterialApp.builder 的 Stack 上,没有 Material 祖先,
      // 文本会回落到 DefaultTextStyle 的下划线样式,这里补一层
      child: Material(
        type: MaterialType.transparency,
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedScale(
            scale: visible ? (_isPressed ? 0.88 : 1.0) : 0.0,
            duration: Duration(milliseconds: _isPressed ? 90 : 220),
            curve: visible && !_isPressed
                ? Curves.easeOutBack
                : Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: visible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: GestureDetector(
                onPanStart: onFloatingPanStart,
                onPanUpdate: onFloatingPanUpdate,
                onPanEnd: onFloatingPanEnd,
                onTapDown: (_) => setState(() => _isPressed = true),
                onTapUp: (_) => setState(() => _isPressed = false),
                onTapCancel: () => setState(() => _isPressed = false),
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
                          Symbols.layers_rounded,
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
                                decoration: TextDecoration.none,
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
          ),
        ),
      ),
    );
  }
}
