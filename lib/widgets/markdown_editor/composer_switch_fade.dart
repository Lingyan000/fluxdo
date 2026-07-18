import 'package:flutter/material.dart';

/// 双模切换的「无并存淡入」壳:child(富/源编辑器)按 key 直切 ——
/// 旧的**同帧从树里移除**(共享 focusNode + 输入模型异构,任何并存
/// 窗口都会让 TextInput 连接交接竞态,AnimatedSwitcher 因此被禁),
/// 新的从透明淡入 [duration],视觉柔和且任意时刻树里只有一个编辑器。
class ComposerSwitchFade extends StatefulWidget {
  const ComposerSwitchFade({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 150),
  });

  final Widget child;
  final Duration duration;

  @override
  State<ComposerSwitchFade> createState() => _ComposerSwitchFadeState();
}

class _ComposerSwitchFadeState extends State<ComposerSwitchFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1, // 首挂载不播(打开页面无闪烁)
  );

  @override
  void didUpdateWidget(covariant ComposerSwitchFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    // key 变化 = 双模切换:新编辑器本帧已替换旧的(旧已 dispose),
    // 从透明淡入
    if (!Widget.canUpdate(oldWidget.child, widget.child)) {
      _fade.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _fade, child: widget.child);
  }
}
