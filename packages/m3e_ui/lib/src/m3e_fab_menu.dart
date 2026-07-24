import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'm3e_flags.dart';
import 'm3e_motion.dart';

/// 一个 FAB 菜单项。
class M3eFabMenuItem {
  final Widget icon;
  final Widget label;
  final VoidCallback onPressed;

  const M3eFabMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
}

/// Material 3 Expressive FAB 菜单。
///
/// 规格对照 Compose FloatingActionButtonMenu.kt:
/// - 展开:FAB 本体 56→48 收小并保持全圆(FabInitialSize/FabFinalSize),
///   图标过渡为关闭 ✕;
/// - 菜单项自下而上 **stagger 入场**(SlowEffects 节拍,项间 ~50ms),
///   每项:宽度 FastSpatial 弹簧 + 透明度 FastEffects;
/// - 菜单项 = primaryContainer 胶囊(高 56,icon+label),右对齐,
///   项间距 8,无 scrim(规格如此;点 FAB 或选项收起);
/// - 收起:反向退场。
///
/// M3E 开关关闭时回退普通 [FloatingActionButton](点击直接展开一个
/// 简易 popup 列)。宿主负责放进 Scaffold.floatingActionButton。
class M3eFabMenu extends StatefulWidget {
  final Widget icon;
  final List<M3eFabMenuItem> items;

  /// 关闭态点击(items 为空时当普通 FAB 用)。
  final VoidCallback? onPressed;

  const M3eFabMenu({
    super.key,
    required this.icon,
    required this.items,
    this.onPressed,
  });

  @override
  State<M3eFabMenu> createState() => M3eFabMenuState();
}

const double _kFabInitialSize = 56;
const double _kFabFinalSize = 48;
const double _kItemHeight = 56;
const double _kItemSpacing = 8;
const int _kStaggerMs = 50;

class M3eFabMenuState extends State<M3eFabMenu>
    with SingleTickerProviderStateMixin {
  bool _open = false;

  /// 展开进度(unbounded,FastSpatial 弹簧,可轻微过冲)。
  late final AnimationController _progress;

  static final SpringDescription _spatial = M3eMotion.fastSpatial.description;

  bool get isOpen => _open;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void toggle() {
    setState(() => _open = !_open);
    // 开合触感:展开中冲量,收起轻冲量。
    if (_open) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
    _progress.animateWith(
      SpringSimulation(_spatial, _progress.value, _open ? 1 : 0, 0),
    );
  }

  void close() {
    if (_open) toggle();
  }

  @override
  Widget build(BuildContext context) {
    final m3e = M3eFlags.of(context).enabled;
    final scheme = Theme.of(context).colorScheme;

    if (!m3e || widget.items.isEmpty) {
      return FloatingActionButton(
        onPressed: widget.items.isEmpty ? widget.onPressed : toggle,
        child: widget.icon,
      );
    }

    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final t = _progress.value.clamp(0.0, 1.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 菜单项:自下而上 stagger(列表最后一项离 FAB 最近、最先入场)。
            for (var i = 0; i < widget.items.length; i++) ...[
              _buildItem(
                scheme,
                widget.items[i],
                // 反向序号:靠近 FAB 的项 stagger 延迟最小。
                widget.items.length - 1 - i,
              ),
              const SizedBox(height: _kItemSpacing),
            ],
            // FAB 本体:56→48 收小保持全圆,图标交叉过渡为 ✕。
            SizedBox(
              width: _kFabInitialSize,
              height: _kFabInitialSize,
              child: Center(
                child: SizedBox(
                  width: _kFabInitialSize -
                      (_kFabInitialSize - _kFabFinalSize) * t,
                  height: _kFabInitialSize -
                      (_kFabInitialSize - _kFabFinalSize) * t,
                  child: Material(
                    shape: const StadiumBorder(),
                    color: t < 0.5
                        ? scheme.primaryContainer
                        : scheme.primary,
                    elevation: 3,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: toggle,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, anim) => RotationTransition(
                            turns: Tween(begin: 0.75, end: 1.0).animate(anim),
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: _open
                              ? Icon(
                                  Icons.close,
                                  key: const ValueKey('close'),
                                  color: scheme.onPrimary,
                                )
                              : KeyedSubtree(
                                  key: const ValueKey('icon'),
                                  child: IconTheme.merge(
                                    data: IconThemeData(
                                      color: scheme.onPrimaryContainer,
                                    ),
                                    child: widget.icon,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildItem(ColorScheme scheme, M3eFabMenuItem item, int staggerIndex) {
    // stagger:每项在总进度上占一个错峰窗口;项进度 = 全局进度平移。
    final total = widget.items.length;
    final windowMs = 300 + _kStaggerMs * total;
    final delay = _kStaggerMs * staggerIndex / windowMs;
    final t = ((_progress.value - delay) / (1 - delay)).clamp(0.0, 1.0);
    if (t <= 0) return const SizedBox.shrink();

    return Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * 12),
        child: SizedBox(
          height: _kItemHeight,
          child: Material(
            shape: const StadiumBorder(),
            color: scheme.primaryContainer,
            elevation: 2,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                close();
                item.onPressed();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconTheme.merge(
                      data: IconThemeData(
                        size: 22,
                        color: scheme.onPrimaryContainer,
                      ),
                      child: item.icon,
                    ),
                    const SizedBox(width: 10),
                    DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: scheme.onPrimaryContainer,
                      ),
                      child: item.label,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
