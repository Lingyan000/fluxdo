import 'dart:math' as math;
import 'dart:ui' show clampDouble, lerpDouble;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../models/shortcut_binding.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/shortcut_provider.dart';
import '../../utils/blur_config.dart';
import '../../utils/responsive.dart';
import 'predictive_back_overlay_handler.dart';

/// 图片长按菜单的操作项。
class ImageLiftAction {
  const ImageLiftAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// 动作回调。菜单 overlay 移除后才执行,无需自行关菜单。
  final VoidCallback onTap;
}

/// 记录实际按下的位置，供折叠屏选区和鼠标菜单定位。无障碍长按没有坐标。
class ImageMenuPress {
  const ImageMenuPress.longPress([this.position]) : secondary = false;
  const ImageMenuPress.secondaryTap(Offset point)
    : position = point,
      secondary = true;

  final Offset? position;
  final bool secondary;
}

/// 帖内图片移交给浮层的预览内容和来源。
class ImageLiftSpec {
  const ImageLiftSpec({
    required this.sourceContext,
    required this.previewBuilder,
    this.press = const ImageMenuPress.longPress(),
    this.sourceRadius = 0,
    this.onPreviewTap,
  });

  /// 源图 BuildContext(取源矩形)。
  final BuildContext sourceContext;

  /// 预览内容 builder(填满预览框,复用源图缓存零闪烁)。
  final WidgetBuilder previewBuilder;

  final ImageMenuPress press;

  /// 源图圆角(网格瓦片 4)。
  final double sourceRadius;

  /// 点按预览时执行，未提供时关闭菜单。
  final VoidCallback? onPreviewTap;
}

/// 图片只在长按成立时浮起。点按交给图片本身，滑动交给所在列表。
class ImageLiftSource extends StatelessWidget {
  const ImageLiftSource({
    super.key,
    required this.onShowMenu,
    required this.child,
  });

  final void Function(BuildContext source, ImageMenuPress press) onShowMenu;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      onLongPress: () => onShowMenu(context, const ImageMenuPress.longPress()),
      child: RawGestureDetector(
        excludeFromSemantics: true,
        gestures: {
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: const Duration(milliseconds: 350),
                  debugOwner: this,
                ),
                (recognizer) => recognizer.onLongPressStart = (event) =>
                    onShowMenu(
                      context,
                      ImageMenuPress.longPress(event.globalPosition),
                    ),
              ),
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (recognizer) => recognizer.onSecondaryTapUp = (event) =>
                    onShowMenu(
                      context,
                      ImageMenuPress.secondaryTap(event.globalPosition),
                    ),
              ),
        },
        child: ValueListenableBuilder<BuildContext?>(
          valueListenable: ImageLiftMenu.activeSource,
          builder: (_, source, child) => Opacity(
            opacity: identical(context, source) ? 0 : 1,
            child: child,
          ),
          child: child,
        ),
      ),
    );
  }
}

typedef _LiftOrigin = ({Rect bounds, Rect visible});

/// 源图和祖先裁切都换算到根浮层坐标，保留滚出视口前的完整图片尺寸。
_LiftOrigin? _readOrigin(BuildContext source, RenderBox overlay) {
  if (!source.mounted || !overlay.attached || !overlay.hasSize) return null;
  RenderObject? box;
  try {
    box = source.findRenderObject();
  } on FlutterError {
    // 列表回收时，元素可能已停用但尚未卸载。
    return null;
  }
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final bounds = MatrixUtils.transformRect(
    box.getTransformTo(overlay),
    Offset.zero & box.size,
  );
  if (!bounds.isFinite || bounds.isEmpty) return null;
  var visible = bounds.intersect(Offset.zero & overlay.size);
  RenderObject descendant = box;
  while (descendant != overlay && descendant.parent != null) {
    final parent = descendant.parent!;
    final clip = parent.describeApproximatePaintClip(descendant);
    if (clip != null) {
      visible = visible.intersect(
        MatrixUtils.transformRect(parent.getTransformTo(overlay), clip),
      );
    }
    descendant = parent;
  }
  return visible.isEmpty ? null : (bounds: bounds, visible: visible);
}

class ImageLiftMenu {
  ImageLiftMenu._();

  /// 浮层接管绘制的图片，关闭后交还给原位的 [ImageLiftSource]。
  static final ValueNotifier<BuildContext?> _activeSource =
      ValueNotifier<BuildContext?>(null);

  static ValueListenable<BuildContext?> get activeSource => _activeSource;

  /// 从源图位置打开操作菜单，无法取得可见来源或已有预览时返回 false。
  static bool show({
    required BuildContext context,
    required WidgetBuilder previewBuilder,
    required List<ImageLiftAction> actions,
    double sourceRadius = 0,
    VoidCallback? onPreviewTap,
    ImageMenuPress press = const ImageMenuPress.longPress(),
  }) {
    if (actions.isEmpty) return false;
    // 同一时刻只允许一个浮起会话(遮罩本就独占输入)。
    if (_activeSource.value != null) return false;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return false;
    final overlayBox = overlay.context.findRenderObject();
    if (overlayBox is! RenderBox) return false;
    final origin = _readOrigin(context, overlayBox);
    if (origin == null) return false;

    // 右键优先让操作列表贴近指针，空间不足时交还普通指针菜单。
    Alignment? pressAnchor;
    if (press.position case final position?) {
      final point = overlayBox.globalToLocal(position);
      if (press.secondary &&
          !_LiftViewport(
            overlayBox.size,
            MediaQuery.of(overlay.context),
            point,
          ).wide) {
        return false;
      }
      final bounds = origin.bounds;
      pressAnchor = Alignment(
        2 * (point.dx - bounds.left) / bounds.width - 1,
        2 * (point.dy - bounds.top) / bounds.height - 1,
      );
    }

    // 模糊偏好与底部弹框同口径(dialog_utils._isBlurEnabled)。
    bool enableBlur = true;
    ShortcutSurfaceRegistryNotifier? shortcutRegistry;
    Object? shortcutOwner;
    try {
      enableBlur = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(preferencesProvider).dialogBlur;
    } catch (_) {
      // 无 ProviderScope 环境(测试等)回退默认开。
    }
    try {
      // 快捷键 surface:挂源页面路由(registry 按「路由精确匹配 + 注册
      // 序」取最新,后注册压过页面自身 surface),ESC 关浮层菜单而非
      // 底下页面;期间其余快捷键按 modal 语义屏蔽。注册失败(无
      // ProviderScope 等)静默降级为纯触摸交互。与模糊偏好分开容错:
      // 偏好读取失败不应连坐屏蔽 ESC 适配。
      shortcutRegistry = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(shortcutSurfaceRegistryProvider.notifier);
      shortcutOwner = Object();
    } catch (_) {
      // 无 ProviderScope 环境(测试等)跳过快捷键注册。
    }

    final route = ModalRoute.of(context);
    final viewKey = GlobalKey<_ImageLiftMenuViewState>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ImageLiftMenuView(
        key: viewKey,
        sourceContext: context,
        route: route,
        origin: origin,
        pressAnchor: pressAnchor,
        secondary: press.secondary,
        overlayBox: overlayBox,
        sourceRadius: sourceRadius,
        previewBuilder: previewBuilder,
        actions: actions,
        onPreviewTap: onPreviewTap,
        enableBlur: enableBlur,
        onDismissed: () {
          entry.remove();
          entry.dispose();
          if (shortcutOwner != null) {
            shortcutRegistry?.unregister(owner: shortcutOwner);
          }
        },
      ),
    );
    if (shortcutRegistry != null && shortcutOwner != null) {
      shortcutRegistry.register(
        owner: shortcutOwner,
        id: ShortcutSurfaceIds.imageLiftMenu,
        triggerAction: ShortcutAction.closeOverlay,
        kind: ShortcutSurfaceKind.overlay,
        repeatBehavior: ShortcutSurfaceRepeatBehavior.dedupe,
        blocksShortcuts: true,
        route: route,
        onClose: () => viewKey.currentState?._requestClose(),
      );
    }
    // 先隐藏源图再插入 overlay:同一帧内预览(与源像素级重合)接管绘制,
    // 源「被拿走」无感切换。
    _activeSource.value = context;
    overlay.insert(entry);
    if (!press.secondary) HapticFeedback.mediumImpact();
    return true;
  }
}

const _openDuration = Duration(milliseconds: 270);
const _closeDuration = Duration(milliseconds: 230);
const _fadeDuration = Duration(milliseconds: 150);
const _panelStart = 0.22;
const _sheetMaxWidth = 480.0;
const _sideGap = 16.0;

/// 根浮层中的可用区域。跨铰链的窗口选取触点所在的一侧。
class _LiftViewport {
  _LiftViewport(Size size, MediaQueryData media, Offset anchor) {
    final window = Offset.zero & size;
    var section = window;
    if (media.displayFeatures.isNotEmpty) {
      final screens = DisplayFeatureSubScreen.subScreensInBounds(
        window,
        DisplayFeatureSubScreen.avoidBounds(media),
      );
      double distance(Rect rect) =>
          (anchor - _inside(rect, anchor)).distanceSquared;
      section = screens.reduce((a, b) => distance(a) <= distance(b) ? a : b);
    }
    bounds = section;
    safe = section.intersect(
      (media.padding + media.viewInsets).deflateRect(window),
    );
  }

  late final Rect bounds;
  late final Rect safe;
  bool get wide => safe.width >= Breakpoints.mobile && safe.height > 0;
}

Offset _inside(Rect rect, Offset point) => Offset(
  clampDouble(point.dx, rect.left, rect.right),
  clampDouble(point.dy, rect.top, rect.bottom),
);

/// 图片先离开原位，面板随后入场。两者都由当前可见进度驱动，收回时沿原路返回。
double _panelProgress(double lift) =>
    ((lift - _panelStart) / (1 - _panelStart)).clamp(0.0, 1.0);

class _ImageLiftMenuView extends StatefulWidget {
  const _ImageLiftMenuView({
    super.key,
    required this.sourceContext,
    required this.route,
    required this.origin,
    required this.pressAnchor,
    required this.secondary,
    required this.overlayBox,
    required this.sourceRadius,
    required this.previewBuilder,
    required this.actions,
    required this.onPreviewTap,
    required this.enableBlur,
    required this.onDismissed,
  });

  final BuildContext sourceContext;
  final ModalRoute<dynamic>? route;
  final _LiftOrigin origin;
  final Alignment? pressAnchor;
  final bool secondary;
  final RenderBox overlayBox;
  final double sourceRadius;
  final WidgetBuilder previewBuilder;
  final List<ImageLiftAction> actions;
  final VoidCallback? onPreviewTap;
  final bool enableBlur;
  final VoidCallback onDismissed;

  @override
  State<_ImageLiftMenuView> createState() => _ImageLiftMenuViewState();
}

class _ImageLiftMenuViewState extends State<_ImageLiftMenuView>
    with TickerProviderStateMixin {
  late final _lift = AnimationController(vsync: this, duration: _openDuration);
  late final _opacity = AnimationController(
    vsync: this,
    value: 1,
    duration: _fadeDuration,
  );
  final _acceptsInput = ValueNotifier(true);
  final _panelKey = GlobalKey();
  late final _scroll = _PanelScrollController(this);
  final _floatingScroll = ScrollController();
  final _menuFocus = FocusScopeNode(debugLabel: 'Image actions');
  FocusNode? _previousFocus;
  (Size, Rect, Rect)? _lastViewport;
  late _LiftOrigin _origin = widget.origin;
  double? _backStart;
  bool _draggingPanel = false;
  bool _sourceRestored = false;

  LocalHistoryEntry? _history;
  PredictiveBackOverlayHandler? _backHandler;

  @override
  void initState() {
    super.initState();
    _open();
    final route = widget.route;
    if (route == null) return;
    _history = LocalHistoryEntry(
      onRemove: () {
        _history = null;
        if (_acceptsInput.value) _requestClose();
      },
    );
    route.addLocalHistoryEntry(_history!);
    _backHandler = PredictiveBackOverlayHandler(
      isEnabled: () => route.isCurrent && _acceptsInput.value,
      onStart: () {
        _lift.stop();
        _refreshOrigin();
        _backStart = _lift.value;
      },
      onUpdate: (progress) {
        if (_acceptsInput.value) _lift.value = _backStart! * (1 - progress);
      },
      onCancel: () {
        _backStart = null;
        if (_acceptsInput.value) _open();
      },
      onCommit: _requestClose,
    )..attach();
  }

  void _open() {
    _lift.animateTo(
      1,
      duration: _openDuration * (1 - _lift.value),
      curve: Curves.fastOutSlowIn,
    );
  }

  bool _refreshOrigin() {
    final origin = _readOrigin(widget.sourceContext, widget.overlayBox);
    if (origin == null) return false;
    if (origin != _origin) setState(() => _origin = origin);
    return true;
  }

  void _restoreSource() {
    if (_sourceRestored) return;
    _sourceRestored = true;
    if (identical(ImageLiftMenu._activeSource.value, widget.sourceContext)) {
      ImageLiftMenu._activeSource.value = null;
    }
  }

  void _requestClose() => _dismiss();

  void _dismiss({VoidCallback? action, double flingSpeed = 0}) {
    if (!_acceptsInput.value) return;
    _acceptsInput.value = false;
    _lift.stop();
    final returnToSource = action == null && _refreshOrigin();
    if (action != null && !widget.secondary) {
      HapticFeedback.selectionClick();
    }
    if (!returnToSource) _restoreSource();
    final exit = returnToSource
        ? _returnToSource(flingSpeed)
        : _opacity.animateBack(0, curve: Curves.easeOut);
    exit.then((_) {
      if (!mounted) return;
      _restoreSource();
      _history?.remove();
      if (_menuFocus.hasFocus &&
          (_previousFocus?.canRequestFocus ?? false) &&
          _previousFocus?.context?.mounted == true) {
        _previousFocus!.requestFocus();
      }
      widget.onDismissed();
      action?.call();
    });
  }

  TickerFuture _returnToSource(double flingSpeed) {
    final distance = _lift.value;
    var duration = _closeDuration * distance;
    Curve curve = Curves.fastOutSlowIn;
    if (flingSpeed > 0) {
      // 匀减速到零，平均速度为松手速度的一半。
      final seconds = 2 * distance / flingSpeed;
      final coast = Duration(
        microseconds: (seconds * Duration.microsecondsPerSecond).round(),
      );
      if (coast < duration) duration = coast;
      curve = Curves.decelerate;
    }
    return _lift.animateBack(0, duration: duration, curve: curve);
  }

  // 列表到顶后把余下的位移交给面板。手指反向时先把面板推回，再继续滚列表。
  double _consumePanelDrag(double delta) {
    if (!_acceptsInput.value || _backStart != null) return delta;
    if (!_draggingPanel && (delta <= 0 || _lift.value <= _panelStart)) {
      return delta;
    }
    final height = _panelHeight;
    if (height <= 0) return delta;
    final before = _panelProgress(_lift.value);
    final after = (before - delta / height).clamp(0.0, 1.0);
    if (before == after) return delta;
    if (!_draggingPanel) _refreshOrigin();
    _draggingPanel = true;
    _lift.value = _panelStart + after * (1 - _panelStart);
    return delta - (before - after) * height;
  }

  double get _panelHeight => _panelKey.currentContext?.size?.height ?? 0;

  bool _releasePanel(double velocity) {
    if (!_draggingPanel) return false;
    _draggingPanel = false;
    if (_acceptsInput.value && _backStart == null) {
      final fling = velocity > 700 && _panelHeight > 0;
      if (_panelProgress(_lift.value) < 0.68 || fling) {
        // 把手指的像素速度换成浮起进度的速度，让快速甩出的面板继续减速滑走。
        _dismiss(
          flingSpeed: fling ? velocity * (1 - _panelStart) / _panelHeight : 0,
        );
      } else {
        _open();
      }
    }
    return _lift.value < 1;
  }

  @override
  void dispose() {
    _acceptsInput.value = false;
    _backHandler?.dispose();
    _history?.remove();
    _restoreSource();
    _menuFocus.dispose();
    _floatingScroll.dispose();
    _scroll.dispose();
    _lift.dispose();
    _opacity.dispose();
    _acceptsInput.dispose();
    super.dispose();
  }

  Widget _buildScrim(BuildContext context) {
    final color = Theme.of(context).colorScheme.scrim;
    return Semantics(
      label: S.current.common_close,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _requestClose,
        child: AnimatedBuilder(
          animation: _lift,
          builder: (_, _) {
            final t = _lift.value;
            final dim = ColoredBox(color: color.withValues(alpha: 0.50 * t));
            if (!widget.enableBlur) return dim;
            return BackdropFilter(
              enabled: t > 0,
              filter: createBlurFilter(4 * t),
              child: dim,
            );
          },
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final shadow = Theme.of(context).colorScheme.shadow;
    final sourceRadius = context.shapes.resolve(widget.sourceRadius);
    final previewRadius = context.shapes.resolve(12);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _dismiss(action: widget.onPreviewTap),
      child: AnimatedBuilder(
        animation: _lift,
        child: Builder(builder: widget.previewBuilder),
        builder: (_, child) {
          final t = _lift.value;
          final radius = BorderRadius.circular(
            lerpDouble(sourceRadius, previewRadius, t)!,
          );
          final (:bounds, :visible) = _origin;
          return DecoratedBox(
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(borderRadius: radius),
              shadows: [
                BoxShadow(
                  color: shadow.withValues(alpha: 0.18 * t),
                  blurRadius: 16 * t,
                  offset: Offset(0, 4 * t),
                ),
              ],
            ),
            child: ClipRSuperellipse(
              borderRadius: radius,
              // 展开裁切窗口，保留长图首帧露在视口里的那一段。
              child: Stack(
                children: [
                  Positioned(
                    left: (bounds.left - visible.left) * (1 - t),
                    top: (bounds.top - visible.top) * (1 - t),
                    right: (visible.right - bounds.right) * (1 - t),
                    bottom: (visible.bottom - bounds.bottom) * (1 - t),
                    child: child!,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPanel(BuildContext context, bool wide) {
    final list = SingleChildScrollView(
      controller: wide ? _floatingScroll : _scroll,
      physics: wide
          ? null
          : const ClampingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in widget.actions)
            ListTile(
              autofocus: wide && identical(action, widget.actions.first),
              minTileHeight: wide ? kMinInteractiveDimension : null,
              contentPadding: wide
                  ? const EdgeInsets.symmetric(horizontal: 16)
                  : null,
              leading: Icon(action.icon, size: wide ? 20 : 22),
              title: Text(action.label),
              onTap: () => _dismiss(action: action.onTap),
            ),
        ],
      ),
    );
    if (!wide) {
      return RepaintBoundary(
        key: _panelKey,
        child: AppSheetScaffold(
          showDragHandle: false,
          contentPadding: EdgeInsets.zero,
          child: list,
        ),
      );
    }

    final theme = Theme.of(context);
    final popup = PopupMenuTheme.of(context);
    final menu = Material(
      color: popup.color ?? theme.colorScheme.surfaceContainerLow,
      elevation: popup.elevation ?? 6,
      shadowColor: popup.shadowColor,
      surfaceTintColor: popup.surfaceTintColor,
      shape:
          popup.shape ??
          RoundedSuperellipseBorder(
            borderRadius: context.shapes.borderRadius(16),
          ),
      clipBehavior: Clip.antiAlias,
      child: list,
    );
    return FocusScope(
      node: _menuFocus,
      autofocus: true,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => _requestClose(),
            ),
          },
          child: AnimatedBuilder(
            animation: _lift,
            child: RepaintBoundary(child: menu),
            builder: (_, child) {
              final progress = _panelProgress(_lift.value);
              return IgnorePointer(
                ignoring: progress == 0,
                child: Opacity(opacity: progress, child: child),
              );
            },
          ),
        ),
      ),
    );
  }

  void _observeViewport(Size size, _LiftViewport viewport) {
    final metrics = (size, viewport.bounds, viewport.safe);
    final previous = _lastViewport;
    if (previous == metrics) return;
    _lastViewport = metrics;
    if (previous == null) return;
    // 横竖切换会卸载原来的底部列表，接回仍停在手指下的浮起进度。
    final settleDrag = viewport.wide && _draggingPanel;
    if (settleDrag) _draggingPanel = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_acceptsInput.value) return;
      _refreshOrigin();
      if (settleDrag && _backStart == null) _open();
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return InteractionGate(
      enabled: _acceptsInput,
      child: BlockSemantics(
        child: FadeTransition(
          opacity: _opacity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final press = widget.pressAnchor?.withinRect(_origin.bounds);
              final anchor = press == null
                  ? _origin.visible.center
                  : _inside(_origin.visible, press);
              final viewport = _LiftViewport(size, media, anchor);
              _observeViewport(size, viewport);
              if (viewport.wide && !_menuFocus.hasFocus) {
                _previousFocus ??= FocusManager.instance.primaryFocus;
              }
              return Stack(
                fit: StackFit.expand,
                children: [
                  _buildScrim(context),
                  CustomMultiChildLayout(
                    delegate: _LiftLayout(
                      origin: _origin,
                      lift: _lift,
                      viewport: viewport,
                      pointer: widget.secondary ? anchor : null,
                    ),
                    children: [
                      LayoutId(
                        id: _LiftPart.preview,
                        child: _buildPreview(context),
                      ),
                      LayoutId(
                        id: _LiftPart.panel,
                        child: _buildPanel(context, viewport.wide),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _LiftPart { preview, panel }

/// 同一轮布局先量操作列表，再给预览分配空间。
class _LiftLayout extends MultiChildLayoutDelegate {
  _LiftLayout({
    required this.origin,
    required this.lift,
    required this.viewport,
    required this.pointer,
  }) : super(relayout: lift);

  final _LiftOrigin origin;
  final Animation<double> lift;
  final _LiftViewport viewport;
  final Offset? pointer;

  Rect _layoutSheet() {
    final screen = viewport.bounds;
    final safe = viewport.safe;
    final panelWidth = math.min(screen.width, _sheetMaxWidth);
    final panel = layoutChild(
      _LiftPart.panel,
      BoxConstraints(
        minWidth: panelWidth,
        maxWidth: panelWidth,
        maxHeight: math.max(
          0,
          safe.height * 0.55 + screen.bottom - safe.bottom,
        ),
      ),
    );
    positionChild(
      _LiftPart.panel,
      Offset(
        screen.center.dx - panel.width / 2,
        screen.bottom - panel.height * _panelProgress(lift.value),
      ),
    );
    final space = Rect.fromLTRB(
      safe.left + 16,
      safe.top + 12,
      safe.right - 16,
      screen.bottom - panel.height - 12,
    );
    final previewSize = applyBoxFit(
      BoxFit.contain,
      origin.bounds.size,
      Size(
        math.max(0, math.min(_sheetMaxWidth, space.width)),
        math.max(0, math.min(screen.height * 0.52, space.height)),
      ),
    ).destination;
    return Rect.fromCenter(
      center: space.center,
      width: previewSize.width,
      height: previewSize.height,
    );
  }

  Rect _layoutBesideSource() {
    // 极矮的横窗也保留可滚动的列表空间。
    final safe = viewport.safe;
    final verticalMargin = math.min(24.0, math.max(0.0, safe.height / 8));
    final area = EdgeInsets.symmetric(
      horizontal: 24,
      vertical: verticalMargin,
    ).deflateRect(safe);
    final panelWidth = clampDouble(area.width * 0.26, 200, 264);
    final panel = layoutChild(
      _LiftPart.panel,
      BoxConstraints(
        minWidth: panelWidth,
        maxWidth: panelWidth,
        maxHeight: math.max(0, area.height),
      ),
    );
    final source = _inside(area, origin.visible.center);
    final click = pointer;
    // 触摸时优先让图片留在来源一侧；右键时优先让首项落在指针旁。
    final menuOnRight = click == null
        ? source.dx <= area.center.dx
        : click.dx >= area.center.dx;
    final contentWidth = area.width - panel.width - _sideGap;
    final double panelX;
    final double previewX;
    final Size previewSize;
    Size fit(double maxWidth) => applyBoxFit(
      BoxFit.contain,
      origin.bounds.size,
      Size(
        math.min(Breakpoints.maxContentWidth, math.max(0, maxWidth)),
        math.max(0, area.height),
      ),
    ).destination;
    if (click != null) {
      panelX = clampDouble(
        menuOnRight ? click.dx - 12 : click.dx - panel.width + 12,
        area.left,
        area.right - panel.width,
      );
      final freeWidth = menuOnRight
          ? panelX - area.left
          : area.right - panelX - panel.width;
      previewSize = fit(freeWidth - _sideGap);
      previewX = menuOnRight
          ? panelX - _sideGap - previewSize.width
          : panelX + panel.width + _sideGap;
    } else {
      previewSize = fit(contentWidth);
      final minX = area.left + (menuOnRight ? 0 : panel.width + _sideGap);
      previewX = clampDouble(
        source.dx - previewSize.width / 2,
        minX,
        minX + math.max(0.0, contentWidth - previewSize.width),
      );
      panelX = menuOnRight
          ? previewX + previewSize.width + _sideGap
          : previewX - panel.width - _sideGap;
    }
    final previewY = clampDouble(
      source.dy - previewSize.height / 2,
      area.top,
      area.top + math.max(0.0, area.height - previewSize.height),
    );
    final panelY = clampDouble(
      click == null
          ? source.dy - panel.height / 2
          : click.dy - 8 - kMinInteractiveDimension / 2,
      area.top,
      area.top + math.max(0.0, area.height - panel.height),
    );
    final reveal = _panelProgress(lift.value);
    positionChild(
      _LiftPart.panel,
      Offset(panelX + (menuOnRight ? -10 : 10) * (1 - reveal), panelY),
    );
    return Offset(previewX, previewY) & previewSize;
  }

  @override
  void performLayout(Size size) {
    final target = viewport.wide ? _layoutBesideSource() : _layoutSheet();
    final t = lift.value;
    final preview = Rect.lerp(origin.visible, target, t)!;
    // 先向屏幕中央靠拢，再完成放大。侧边缩略图浮起时因此有一条浅弧线。
    final centerX = lerpDouble(
      origin.visible.center.dx,
      target.center.dx,
      Curves.easeOutCubic.transform(t),
    )!;
    final double left = clampDouble(
      centerX - preview.width / 2,
      0.0,
      math.max(0.0, size.width - preview.width),
    );
    layoutChild(_LiftPart.preview, BoxConstraints.tight(preview.size));
    positionChild(_LiftPart.preview, Offset(left, preview.top));
  }

  @override
  bool shouldRelayout(_LiftLayout oldDelegate) =>
      origin != oldDelegate.origin ||
      viewport.bounds != oldDelegate.viewport.bounds ||
      viewport.safe != oldDelegate.viewport.safe ||
      pointer != oldDelegate.pointer ||
      lift != oldDelegate.lift;
}

class _PanelScrollController extends ScrollController {
  _PanelScrollController(this.menu);
  final _ImageLiftMenuViewState menu;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _PanelScrollPosition(
    menu: menu,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _PanelScrollPosition extends ScrollPositionWithSingleContext {
  _PanelScrollPosition({
    required this.menu,
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  final _ImageLiftMenuViewState menu;

  @override
  void applyUserOffset(double delta) {
    if (delta > 0 && pixels > minScrollExtent) {
      final contentDelta = math.min(delta, pixels - minScrollExtent);
      super.applyUserOffset(contentDelta);
      delta -= contentDelta;
    }
    final remaining = menu._consumePanelDrag(delta);
    if (remaining != 0) super.applyUserOffset(remaining);
  }

  @override
  void goBallistic(double velocity) {
    final handled = menu._releasePanel(-velocity);
    super.goBallistic(handled ? 0 : velocity);
  }
}
