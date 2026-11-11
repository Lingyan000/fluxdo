import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import 'festival_motif.dart';

/// 节日期间注入组件库 [UiDecor] 的点缀。都是顶层函数，引用恒定，
/// 节日没变化时不会通知依赖方重建。

/// 空状态图标右上角的节日图案
Widget festivalCornerBadge(BuildContext context) =>
    const _CurrentFestivalMotif(size: 26);

/// 下拉刷新圆片里的加载动画：节日图案本身持续循环播放自己的动画
Widget festivalLoadingIndicator(BuildContext context, double size) =>
    _FestivalSpinner(size: size);

class _CurrentFestivalMotif extends ConsumerWidget {
  const _CurrentFestivalMotif({
    required this.size,
    this.phase = 0,
    this.intensity = 0,
  });

  final double size;
  final double phase;
  final double intensity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(
      themeProvider.select((s) => s.activeFestival?.festival.id),
    );
    if (id == null || !FestivalMotif.ids.contains(id)) {
      return SizedBox.square(dimension: size);
    }
    return FestivalMotif(
      festivalId: id,
      size: size,
      phase: phase,
      intensity: intensity,
    );
  }
}

class _FestivalSpinner extends StatefulWidget {
  const _FestivalSpinner({required this.size});

  final double size;

  @override
  State<_FestivalSpinner> createState() => _FestivalSpinnerState();
}

class _FestivalSpinnerState extends State<_FestivalSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => _CurrentFestivalMotif(
      size: widget.size,
      phase: _controller.value,
      intensity: 1,
    ),
  );
}
