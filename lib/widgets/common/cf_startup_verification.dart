import 'package:common_ui/common_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// 启动页决定网页的位置和尺寸，验证会话持有同一个平台视图。
class CfStartupVerificationHost extends ChangeNotifier {
  final viewportLink = LayerLink();
  Size _viewportSize = Size.zero;
  double _coveredTop = 0;
  Color? loadingBackground;
  bool pageVisible = false;
  VoidCallback? reloadPage;
  VoidCallback? cancelVerification;

  void layoutViewport(Size size, {double coveredTop = 0}) {
    if (_viewportSize == size && _coveredTop == coveredTop) return;
    _viewportSize = size;
    _coveredTop = coveredTop;
    _notify();
  }

  void present({bool pageVisible = false, VoidCallback? reloadPage}) {
    if (this.pageVisible == pageVisible && this.reloadPage == reloadPage) {
      return;
    }
    this.pageVisible = pageVisible;
    this.reloadPage = reloadPage;
    _notify();
  }

  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (hasListeners) notifyListeners();
      });
    } else if (hasListeners) {
      notifyListeners();
    }
  }
}

class CfStartupVerificationViewport extends StatelessWidget {
  const CfStartupVerificationViewport({
    super.key,
    required this.host,
    required this.child,
  });

  final CfStartupVerificationHost host;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: host,
    child: child,
    builder: (context, browser) => Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: host.viewportLink,
        showWhenUnlinked: false,
        child: SizedBox.fromSize(
          size: host._viewportSize,
          child: ClipRect(
            // 等待时只绘制标题下方的空白区域，完整平台视图始终使用同一组约束。
            clipper: host.pageVisible ? null : _BelowHeader(host._coveredTop),
            child: ClipRRect(
              borderRadius: context.shapes.borderRadius(12),
              child: CfVerificationWebView(
                visible: host.pageVisible,
                loadingBackground: host.loadingBackground,
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: browser,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _BelowHeader extends CustomClipper<Rect> {
  const _BelowHeader(this.top);
  final double top;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    0,
    top.clamp(0, size.height).toDouble(),
    size.width,
    size.height,
  );

  @override
  bool shouldReclip(_BelowHeader oldClipper) => top != oldClipper.top;
}

/// 检查时由 Flutter 显示加载界面，人工操作直接交给同一个完整 WebView。
class CfVerificationWebView extends StatelessWidget {
  const CfVerificationWebView({
    super.key,
    required this.visible,
    required this.loadingBackground,
    required this.child,
  });

  final bool visible;
  final Color? loadingBackground;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final background = loadingBackground;
    return ExcludeSemantics(
      excluding: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: IgnorePointer(
          ignoring: !visible,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 有实色背景时允许平台视图从首帧正常绘制。透明窗口让出底层内容。
              Offstage(offstage: !visible && background == null, child: child),
              if (!visible && background != null) ColoredBox(color: background),
            ],
          ),
        ),
      ),
    );
  }
}

/// 从当前可见的入口揭开面板。WebView 始终布局在最终位置。
class CfVerificationPanelReveal extends StatelessWidget {
  const CfVerificationPanelReveal({
    super.key,
    required this.from,
    required this.bounds,
    required this.barrier,
    required this.child,
  });

  final Rect from;
  final Rect bounds;
  final Widget barrier;
  final Widget child;

  static Rect? anchorIn(GlobalKey key, BuildContext overlay) {
    final anchor = key.currentContext?.findRenderObject();
    final root = overlay.findRenderObject();
    if (anchor is! RenderBox ||
        !anchor.attached ||
        !anchor.hasSize ||
        root is! RenderBox ||
        !root.hasSize) {
      return null;
    }
    final rect =
        (anchor.localToGlobal(Offset.zero, ancestor: root) & anchor.size)
            .intersect(Offset.zero & root.size);
    return rect.isEmpty ? null : rect;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      child: child,
      builder: (context, t, child) {
        final frame = Rect.lerp(from, bounds, t)!;
        final radius = context.shapes.borderRadius(20);
        return AbsorbPointer(
          absorbing: t < 1,
          child: Stack(
            children: [
              Positioned.fill(
                child: Opacity(opacity: t, child: barrier),
              ),
              Positioned.fromRect(
                rect: bounds,
                child: ClipRRect(
                  clipBehavior: t == 1 ? Clip.none : Clip.antiAlias,
                  clipper: _VerificationClip(
                    radius.toRRect(frame.shift(-bounds.topLeft)),
                  ),
                  child: child,
                ),
              ),
              if (t < 1)
                Positioned.fromRect(
                  rect: frame,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        color: Theme.of(context).colorScheme.surface.withValues(
                          alpha: 1 - const Interval(0.25, 1).transform(t),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _VerificationClip extends CustomClipper<RRect> {
  const _VerificationClip(this.clip);

  final RRect clip;

  @override
  RRect getClip(Size size) => clip;

  @override
  bool shouldReclip(_VerificationClip old) => old.clip != clip;
}
