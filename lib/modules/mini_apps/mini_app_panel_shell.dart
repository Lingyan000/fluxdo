import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../utils/platform_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';

/// 话题内的运行弹窗：手机贴底、桌面居中，沿用公共弹层外壳。
class MiniAppPanelShell extends StatefulWidget {
  const MiniAppPanelShell({
    super.key,
    required this.builder,
    this.onHeightChanged,
  });
  final Widget Function(ValueChanged<bool> onFullscreenChanged) builder;
  final ValueChanged<double>? onHeightChanged;

  @override
  State<MiniAppPanelShell> createState() => _MiniAppPanelShellState();
}

class _MiniAppPanelShellState extends State<MiniAppPanelShell> {
  bool _fullscreen = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = PlatformUtils.isDesktop;
      final media = MediaQuery.of(context);
      final availableHeight = constraints.maxHeight;
      final height = _fullscreen
          ? availableHeight
          : desktop
          ? math.min(760.0, math.max(0.0, availableHeight - 48))
          : math.min(
              media.size.height * .8,
              math.max(0.0, availableHeight - media.padding.top - 12),
            );
      widget.onHeightChanged?.call(height);
      return Align(
        alignment: desktop ? Alignment.center : Alignment.bottomCenter,
        heightFactor: 1,
        child: SizedBox(
          width: desktop && !_fullscreen
              ? math.min(960, math.max(0, constraints.maxWidth - 48)).toDouble()
              : constraints.maxWidth,
          height: height,
          child: AppSheetScaffold(
            expandToFill: true,
            showCloseButton: false,
            showDragHandle: !desktop && !_fullscreen,
            contentPadding: EdgeInsets.zero,
            borderRadius: _fullscreen
                ? BorderRadius.zero
                : desktop
                ? BorderRadius.circular(28)
                : const BorderRadius.vertical(top: Radius.circular(28)),
            child: widget.builder((value) {
              if (mounted && value != _fullscreen) {
                setState(() => _fullscreen = value);
              }
            }),
          ),
        ),
      );
    },
  );
}
