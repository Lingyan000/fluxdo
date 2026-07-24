import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'm3e_flags.dart';
import 'm3e_motion.dart';

/// Material 3 Expressive 底部导航栏:选中指示器 pill 在 tab 之间
/// **弹簧滑动**(而非原生的原地淡入)。
///
/// 实现:原生 [NavigationBar] 的 indicator 置透明,自绘 pill 层叠在
/// 其下方,位置由 [M3eMotion.fastSpatial] 弹簧驱动 —— 切 tab 时 pill
/// 从旧位置滑到新位置,带轻微过冲;图标/文字/语义仍全部由原生
/// NavigationBar 负责,行为零差异。
///
/// M3E 开关关闭时回退原生 [NavigationBar]。
class M3eNavigationBar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  const M3eNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  @override
  State<M3eNavigationBar> createState() => _M3eNavigationBarState();
}

/// M3 指示器规格(NavigationBarTokens):64×32,圆角全圆;
/// 显示 label 时指示器顶边距 12。
const double _kIndicatorWidth = 64;
const double _kIndicatorHeight = 32;
const double _kIndicatorTop = 12;

class _M3eNavigationBarState extends State<M3eNavigationBar>
    with SingleTickerProviderStateMixin {
  /// 指示器位置(以 tab 序号为单位的连续值),弹簧驱动。
  late final AnimationController _position;

  static final SpringDescription _spring = M3eMotion.fastSpatial.description;

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(vsync: this)
      ..value = widget.selectedIndex.toDouble();
  }

  @override
  void didUpdateWidget(M3eNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      _position.animateWith(
        SpringSimulation(
          _spring,
          _position.value,
          widget.selectedIndex.toDouble(),
          0,
        ),
      );
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!M3eFlags.of(context).enabled) {
      return NavigationBar(
        selectedIndex: widget.selectedIndex,
        onDestinationSelected: widget.onDestinationSelected,
        destinations: widget.destinations,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final barTheme = NavigationBarTheme.of(context);
    // 原生底色前置到 Stack 最底层(原生 bar 自身置透明让 pill 可见)。
    final background = barTheme.backgroundColor ?? scheme.surfaceContainer;
    return ColoredBox(
      color: background,
      child: Stack(
        children: [
          // 自绘滑动 pill:位置 = 连续 tab 序号 × 槽宽,弹簧插值。
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _position,
                builder: (context, _) {
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final slot =
                          constraints.maxWidth / widget.destinations.length;
                      final center = slot * (_position.value + 0.5);
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Transform.translate(
                          offset: Offset(
                            center - _kIndicatorWidth / 2,
                            _kIndicatorTop,
                          ),
                          child: Container(
                            width: _kIndicatorWidth,
                            height: _kIndicatorHeight,
                            decoration: ShapeDecoration(
                              color: scheme.secondaryContainer,
                              shape: const StadiumBorder(),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          // 原生 NavigationBar:自身 indicator 透明(pill 由上层自绘),
          // 背景也透明让自绘层可见 —— 底色由外层 ColoredBox 补。
          NavigationBarTheme(
            data: NavigationBarTheme.of(context).copyWith(
              indicatorColor: Colors.transparent,
              backgroundColor: Colors.transparent,
            ),
            child: NavigationBar(
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: widget.onDestinationSelected,
              destinations: widget.destinations,
            ),
          ),
        ],
      ),
    );
  }
}
