import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../utils/platform_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/browser/browser_dock_motion.dart';
import 'mini_app_panel_motion.dart';

/// 话题内的运行弹窗：手机贴底、桌面居中，沿用公共弹层外壳。
class MiniAppPanelShell extends StatefulWidget {
  const MiniAppPanelShell({
    super.key,
    required this.builder,
    this.onHeightChanged,
    this.motion,
  });
  final Widget Function(ValueChanged<bool> onFullscreenChanged) builder;
  final ValueChanged<double>? onHeightChanged;
  final MiniAppPanelMotion? motion;

  @override
  State<MiniAppPanelShell> createState() => _MiniAppPanelShellState();
}

class _MiniAppPanelShellState extends State<MiniAppPanelShell> {
  bool _fullscreen = false;
  final _headerBounds = GlobalKey();

  bool _canStart(PointerEvent event) {
    if (_fullscreen || widget.motion?.canDrag?.call() != true) return false;
    final box = _headerBounds.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final point = box.globalToLocal(event.position);
    final toolbar = MediaQuery.orientationOf(context) == Orientation.landscape
        ? 48
        : 56;
    // 包含公共把手的 24dp 与原生工具栏；不让识别器参加网页内容区的竞争。
    return point.dx >= 0 &&
        point.dx < box.size.width &&
        point.dy >= 0 &&
        point.dy < 24 + toolbar;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = PlatformUtils.isDesktop;
      final localMedia = MediaQuery.of(context);
      final media = BrowserDockViewport.maybeOf(context)?.media ?? localMedia;
      final bottomInset = (media.size.height - localMedia.size.height).clamp(
        0.0,
        double.infinity,
      );
      final availableHeight =
          constraints.maxHeight + (desktop ? 0 : bottomInset);
      final height = _fullscreen
          ? availableHeight
          : desktop
          ? math.min(760.0, math.max(0.0, availableHeight - 48))
          : math.min(
              media.size.height * .8,
              math.max(0.0, availableHeight - media.padding.top - 12),
            );
      widget.onHeightChanged?.call(height);
      return Transform.translate(
        offset: Offset(0, desktop ? 0 : bottomInset),
        child: MediaQuery(
          data: desktop ? localMedia : media,
          child: Align(
            alignment: desktop ? Alignment.center : Alignment.bottomCenter,
            heightFactor: 1,
            child: SizedBox(
              width: desktop && !_fullscreen
                  ? math
                        .min(960, math.max(0, constraints.maxWidth - 48))
                        .toDouble()
                  : constraints.maxWidth,
              height: height,
              child: RawGestureDetector(
                key: _headerBounds,
                behavior: HitTestBehavior.translucent,
                gestures: {
                  if (!desktop && widget.motion != null)
                    _HeaderDragRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _HeaderDragRecognizer
                        >(
                          _HeaderDragRecognizer.new,
                          (recognizer) => recognizer
                            ..allowed = _canStart
                            ..onDown = (_) {
                              widget.motion?.hold();
                            }
                            ..onUpdate = (event) {
                              widget.motion?.drag(event.delta.dy);
                            }
                            ..onEnd = (event) {
                              widget.motion?.release(
                                event.primaryVelocity ?? 0,
                              );
                            }
                            ..onCancel = () {
                              widget.motion?.cancel();
                            },
                        ),
                },
                child: RepaintBoundary(
                  child: AppSheetScaffold(
                    expandToFill: true,
                    showCloseButton: false,
                    showDragHandle: !desktop && !_fullscreen,
                    contentPadding: EdgeInsets.zero,
                    borderRadius: _fullscreen
                        ? BorderRadius.zero
                        : desktop
                        ? context.shapes.borderRadius(28)
                        : BorderRadius.vertical(top: context.shapes.radius(28)),
                    child: widget.builder((value) {
                      if (mounted && value != _fullscreen) {
                        setState(() => _fullscreen = value);
                      }
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _HeaderDragRecognizer extends VerticalDragGestureRecognizer {
  bool Function(PointerEvent)? allowed;
  @override
  bool isPointerAllowed(PointerEvent event) =>
      allowed?.call(event) == true && super.isPointerAllowed(event);
}
