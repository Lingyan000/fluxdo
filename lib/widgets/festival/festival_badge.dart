import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../theme/theme_spec.dart';
import 'festival_motif.dart';

/// 首页标题旁的节日挂件：静止显示节日图案，点一下完整播一遍动画并
/// 显示祝福。节日装饰未生效时不占位。
class FestivalBadge extends ConsumerStatefulWidget {
  const FestivalBadge({super.key, this.size = 22});

  final double size;

  @override
  ConsumerState<FestivalBadge> createState() => _FestivalBadgeState();
}

class _FestivalBadgeState extends ConsumerState<FestivalBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  final _tooltipKey = GlobalKey<TooltipState>();

  /// 点一下：动一次并显示祝福（桌面端 Tooltip 不支持点击触发，需主动显示）
  void _play() {
    HapticFeedback.lightImpact();
    _controller.forward(from: 0);
    _tooltipKey.currentState?.ensureTooltipVisible();
  }

  @override
  Widget build(BuildContext context) {
    final festival = ref.watch(
      themeProvider.select(
        (s) => s.isFestivalDecorActive ? s.activeFestival?.festival : null,
      ),
    );
    if (festival == null || !FestivalMotif.ids.contains(festival.id)) {
      return const SizedBox.shrink();
    }
    final greeting = localizedName(
      festival.greeting,
      Localizations.localeOf(context),
      festival.id,
    );
    return Tooltip(
      key: _tooltipKey,
      message: greeting,
      triggerMode: TooltipTriggerMode.manual,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _play,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => FestivalMotif(
                festivalId: festival.id,
                size: widget.size,
                phase: _controller.value,
                intensity: _controller.isAnimating
                    ? _envelope(_controller.value)
                    : 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 播一遍时的动效强度：开头和结尾各用 15% 的时长渐入渐出，
/// 从静止平滑进入动画、再平滑回到静止。
double _envelope(double t) {
  const edge = 0.15;
  if (t < edge) return Curves.easeOut.transform(t / edge);
  if (t > 1 - edge) return Curves.easeIn.transform((1 - t) / edge);
  return 1;
}
