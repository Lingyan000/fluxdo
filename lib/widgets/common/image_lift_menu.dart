import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../models/shortcut_binding.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/shortcut_provider.dart';
import '../../utils/blur_config.dart';
import 'fading_edge_scroll_view.dart';

/// X(Twitter)风格「长按浮起」图片上下文菜单的动作项。
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

/// X(Twitter)风格图片长按菜单:对齐 X 在 iOS 上的系统级
/// `UIContextMenuInteraction` 动效(iOS 16 起 iPhone 上的呈现形态)。
///
/// 一次长按同时出现三样东西,共同构成一个整体动画:
///
/// 1. **图片浮起(lift)** —— 预览图从源矩形"脱离"(Apple HIG 原文
///    "the system animates the preview image as it emerges from the
///    content"),以单一弹簧同时做位移 + 缩放,飞到屏幕中上部预览位,
///    圆角渐变为 12、阴影渐显;
/// 2. **背景模糊 + 压暗** —— 整个屏幕(含源图原位)被高斯模糊并叠加
///    dim 层("dimming the screen behind the preview and the menu"),
///    预览与菜单在其上保持清晰;
/// 3. **底部动作面板** —— 同一弹簧从屏幕底缘滑入,大图标按钮阵列
///    (iOS 16 上下文菜单的底部面板形态,X 的图片菜单即此样式)。
///
/// 关闭方式(对齐 iOS 交互):
/// - 点按遮罩空白处:弹簧回落,预览图回到源矩形;
/// - 面板下拉:面板跟手位移,超过阈值/速度继续滑出并整体收回;
/// - 点选动作:整体快速淡出(X/iOS 选动作不回弹,直接消散)后执行回调。
///
/// 弹簧参数按 iOS 上下文菜单实测口径(response≈0.35s,damping
/// ratio≈0.78,整体 ≈0.4s,几乎无过冲),见 [_LiftSpringCurve]。
/// 浮起菜单源信息包:调用方(ImageContextMenu)汇总传入,避免参数发散。
class ImageLiftSpec {
  const ImageLiftSpec({
    required this.sourceContext,
    required this.previewBuilder,
    this.sourceRadius = 0,
    this.onPreviewTap,
  });

  /// 源图 BuildContext(取源矩形)。
  final BuildContext sourceContext;

  /// 预览内容 builder(填满预览框,复用源图缓存零闪烁)。
  final WidgetBuilder previewBuilder;

  /// 源图圆角(网格瓦片 4)。
  final double sourceRadius;

  /// 点预览回调(iOS 语义:点预览打开内容);null 时点预览关闭菜单。
  final VoidCallback? onPreviewTap;
}

class ImageLiftMenu {
  ImageLiftMenu._();

  /// 当前浮起会话的源 element(非 null = 会话进行中)。
  ///
  /// 源图处以 [ValueListenableBuilder] 监听本 notifier:值与自身 context
  /// 同一(identical)时以 `Opacity(0)` 隐藏 —— X/iOS lift 语义:源视图
  /// 被「拿走」浮起,原位空缺,与查看大图的 Hero 飞行一致;落回/淡出
  /// 时恢复。
  static final ValueNotifier<BuildContext?> _activeSource =
      ValueNotifier<BuildContext?>(null);

  static ValueListenable<BuildContext?> get activeSource => _activeSource;

  /// 弹出浮起菜单。
  ///
  /// [context] 源图片的 BuildContext,用于取源矩形(全局坐标)与
  /// Overlay;[previewBuilder] 返回填满预览框的内容(同一图片 provider
  /// / SVG 会话缓存,零闪烁);[actions] 动作项;[sourceRadius] 源图
  /// 圆角(网格瓦片传 4,动画中插值到预览圆角);[onPreviewTap] 点按
  /// 预览图的回调(iOS 语义:点预览打开内容),null 时点预览关闭菜单。
  ///
  /// 返回是否成功弹出(取不到源矩形/动作为空/已有会话时返回 false,
  /// 调用方可回退到其他菜单形态)。
  static bool show({
    required BuildContext context,
    required WidgetBuilder previewBuilder,
    required List<ImageLiftAction> actions,
    double sourceRadius = 0,
    VoidCallback? onPreviewTap,
  }) {
    if (actions.isEmpty) return false;
    // 同一时刻只允许一个浮起会话(遮罩本就独占输入)。
    if (_activeSource.value != null) return false;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return false;
    }
    final rawRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (rawRect.isEmpty || rawRect.hasNaN) return false;
    // 源盒子可能比窗口还大/部分出屏(unbounded 容器:横滚内容、按原图
    // 尺寸排的盒子等),此时从完整源矩形起飞会让飞行前段全部在屏幕外
    // (预览「跑到外面」)。动画起点取与窗口的交集 —— 用户实际看到的
    // 那一部分;图片完整宽高比另记(_contentAspect)供目标矩形计算。
    final windowRect = Offset.zero & MediaQuery.sizeOf(context);
    final sourceRect = rawRect.intersect(windowRect);
    if (sourceRect.isEmpty) return false;
    final contentAspect = rawRect.width / rawRect.height;

    // 模糊偏好与底部弹框同口径(dialog_utils._isBlurEnabled)。
    bool enableBlur = true;
    ShortcutSurfaceRegistryNotifier? shortcutRegistry;
    Object? shortcutOwner;
    try {
      enableBlur =
          ProviderScope.containerOf(
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

    final overlay = Overlay.of(context, rootOverlay: true);
    final viewKey = GlobalKey<_ImageLiftMenuViewState>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ImageLiftMenuView(
        key: viewKey,
        sourceContext: context,
        sourceRect: sourceRect,
        contentAspect: contentAspect,
        sourceRadius: sourceRadius,
        previewBuilder: previewBuilder,
        actions: actions,
        onPreviewTap: onPreviewTap,
        enableBlur: enableBlur,
        onDismissed: () {
          entry.remove();
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
        route: ModalRoute.of(context),
        onClose: () => viewKey.currentState?._requestClose(),
      );
    }
    // 先隐藏源图再插入 overlay:同一帧内预览(与源像素级重合)接管绘制,
    // 源「被拿走」无感切换。
    _activeSource.value = context;
    overlay.insert(entry);
    HapticFeedback.mediumImpact();
    return true;
  }
}

/// 生命周期:等测量 → 浮起 → 常驻 → 收回/淡出。
enum _LiftPhase { waitingMeasure, opening, open, closing, fading }

const Duration _kOpenDuration = Duration(milliseconds: 420);
const Duration _kCloseDuration = Duration(milliseconds: 380);
const Duration _kFadeDuration = Duration(milliseconds: 200);

const double _kPreviewMarginH = 24;
const double _kPreviewMaxWidth = 480; // 大屏(iPad/桌面)不铺满全宽
const double _kPreviewMaxHeightFactor = 0.52;
const double _kPreviewTargetRadius = 12;
const double _kPanelCornerRadius = 20; // 对齐 AppSheetScaffold 外壳
const double _kPanelMaxWidth = 480; // 大屏面板居中限宽,两侧可点遮罩关闭
const double _kSpringSpanSec = 0.42;

/// 度量变化后布局稳定所需的观察帧数上限(LayoutBuilder 链、sliver
/// 惰性重排会跨多帧,单帧测量会拿到中间态)。
const int _kSettleFrames = 8;

/// iOS 上下文菜单浮起弹簧:response≈0.35s、damping ratio≈0.78
/// (社区对 UIKit 的实测口径),对应 stiffness=(2π/0.35)²≈322.5、
/// damping=2·0.78·√322.5≈28.0,微量过冲(≈2%)后快速稳态。
class _LiftSpringCurve extends Curve {
  const _LiftSpringCurve();

  static final SpringSimulation _sim = SpringSimulation(
    const SpringDescription(mass: 1, stiffness: 322.5, damping: 28.0),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) {
    final value = _sim.x(t * _kSpringSpanSec);
    return value < 0 ? 0.0 : value;
  }
}

const Curve _spring = _LiftSpringCurve();

class _ImageLiftMenuView extends StatefulWidget {
  const _ImageLiftMenuView({
    super.key,
    required this.sourceContext,
    required this.sourceRect,
    required this.contentAspect,
    required this.sourceRadius,
    required this.previewBuilder,
    required this.actions,
    required this.onPreviewTap,
    required this.enableBlur,
    required this.onDismissed,
  });

  /// 源图 element:会话期间 `ImageLiftMenu.activeSource` 指向它,
  /// 源图据此隐藏;结束时清除。
  final BuildContext sourceContext;

  /// 动画起点的源矩形(已与窗口求交,恒在视口内)。
  final Rect sourceRect;

  /// 图片完整宽高比(未与窗口求交的原始盒子计算):目标矩形按它等比,
  /// 源盒子超屏被裁时预览内容比例仍正确。
  final double contentAspect;
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _master = AnimationController(vsync: this);
  late final AnimationController _dragReset = AnimationController(vsync: this);

  final GlobalKey _panelKey = GlobalKey();

  _LiftPhase _phase = _LiftPhase.waitingMeasure;

  /// 源矩形(可变:窗口/旋转变化时重测并与窗口求交,见 [didChangeMetrics])。
  late Rect _sourceRect = widget.sourceRect;

  /// 图片完整宽高比(随重测更新)。
  late double _contentAspect = widget.contentAspect;
  /// 面板实测高度(首帧后测量面板再起动画)。
  double _panelHeight = 0;

  /// 预览目标矩形在 build 期从当前 MediaQuery 派生(见 [build]):窗口
  /// 尺寸变化触发的重建同一帧即拿到新几何,不依赖 settle 回调链——
  /// postFrame 回调不保证有后续帧,且源 element 被卸载后回调链可能
  /// 中断,存量的目标矩形会永远停留在旧窗口尺寸(预览稳态越屏)。

  /// 度量变化后的稳定观察剩余帧数与调度去重(见 [didChangeMetrics])。
  int _settleFrames = 0;
  bool _settleScheduled = false;

  /// 源 element 已卸载(列表回收等):关闭时不再飞回原位,原地淡出。
  bool _sourceDetached = false;

  /// 重测发现源盒子整体移出视口(大改重排/横滚翻页):关闭原地淡出。
  bool _sourceOffscreen = false;

  /// 面板下拉跟手位移(常驻态)与收回时冻结的起始位移。
  double _dragOffset = 0;
  double _frozenDrag = 0;
  Animation<double>? _dragResetAnim;

  /// 淡出后待执行的动作回调。
  VoidCallback? _pendingCallback;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _master.addStatusListener(_onMasterStatus);
    // 首帧:预览盖在源图上(像素级重合)、遮罩全透明、面板移出屏外,
    // 测得面板高度与预览目标矩形后再开始浮起动画,延迟一帧不可感知。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndOpen());
  }

  @override
  void dispose() {
    // 防御:overlay entry 被外部移除时也保证源图恢复可见。
    if (identical(ImageLiftMenu._activeSource.value, widget.sourceContext)) {
      ImageLiftMenu._activeSource.value = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _master.dispose();
    _dragReset.dispose();
    super.dispose();
  }

  /// 窗口/屏幕度量变化(桌面拖拽边缘、旋转、分屏):预览目标位、面板
  /// 定位与源矩形都可能失效,重测后整体跳到新布局。连续拖拽时逐帧
  /// 跟随,与原生浮层的重排行为一致。
  ///
  /// 大改动会引发**多帧级联重排**(LayoutBuilder 链、sliver 惰性重排、
  /// 图片占位切换),单帧测量会拿到中间态;故在度量变化后的数帧内
  /// 持续重测,直到矩形不再变化(见 [_kSettleFrames])。
  @override
  void didChangeMetrics() {
    // 首测尚未进行:几何信息由 [_measureAndOpen] 统一建立。
    if (_phase == _LiftPhase.waitingMeasure) return;
    _settleFrames = _kSettleFrames;
    _scheduleSettleMeasure();
  }

  void _scheduleSettleMeasure() {
    if (_settleScheduled || _settleFrames <= 0 || !mounted) return;
    _settleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleScheduled = false;
      if (!mounted ||
          _settleFrames <= 0 ||
          _phase == _LiftPhase.closing ||
          _phase == _LiftPhase.fading) {
        return;
      }
      _settleFrames--;
      final changed = _remeasureGeometry();
      // 还有剩余帧且期间仍有变化 → 继续观察;无变化时提前停止。
      if (_settleFrames > 0 && (changed || _settleFrames == _kSettleFrames - 1)) {
        _scheduleSettleMeasure();
      }
    });
  }

  /// 重测源矩形/面板高度/窗口尺寸,有实际变化时重算目标并重建。
  bool _remeasureGeometry() {
    var changed = false;

    // 重测源矩形:窗口变化引起文档流重排,源图位置随实际布局走;与窗口
    // 求交(unbounded 盒子可能超屏),并同步完整宽高比。源 element 已
    // 卸载(sliver 回收、响应式布局切换重挂载等)保持旧矩形并标记
    // detached,源整体移出视口标记 offscreen —— 两种情况关闭时都按
    // 「无源」处理(原地淡出)。
    //
    // 防护:非 active 的 element 在 debug 下 findRenderObject 直接抛
    // FlutterError(而非返回 null)——不挡的话异常会中断 settle 回调链,
    // 后续窗口变化永远无法重测。
    final sourceContext = widget.sourceContext;
    RenderObject? renderObject;
    if (sourceContext.mounted) {
      try {
        renderObject = sourceContext.findRenderObject();
      } catch (_) {
        renderObject = null;
      }
    }
    final screen = MediaQuery.sizeOf(context);
    if (renderObject is RenderBox &&
        renderObject.attached &&
        renderObject.hasSize) {
      final rect =
          renderObject.localToGlobal(Offset.zero) & renderObject.size;
      if (!rect.hasNaN && !rect.isEmpty) {
        final visible = rect.intersect(Offset.zero & screen);
        if (visible.isEmpty) {
          if (!_sourceOffscreen) {
            _sourceOffscreen = true;
            changed = true;
          }
        } else {
          if (_sourceRect != visible) {
            _sourceRect = visible;
            changed = true;
          }
          final aspect = rect.width / rect.height;
          if (_contentAspect != aspect) {
            _contentAspect = aspect;
            changed = true;
          }
          if (_sourceOffscreen) {
            _sourceOffscreen = false;
            changed = true;
          }
        }
        if (_sourceDetached) {
          _sourceDetached = false;
          changed = true;
        }
      }
    } else if (!_sourceDetached) {
      _sourceDetached = true;
    }

    final panelRenderObject = _panelKey.currentContext?.findRenderObject();
    if (panelRenderObject is RenderBox && panelRenderObject.hasSize) {
      final height = panelRenderObject.size.height;
      if (_panelHeight != height) {
        _panelHeight = height;
        changed = true;
      }
    }

    if (changed) {
      setState(() {});
    }
    return changed;
  }

  void _measureAndOpen() {
    if (!mounted) return;
    final renderObject = _panelKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      _panelHeight = renderObject.size.height;
    } else {
      _panelHeight = 180; // 测不到时的保守估值,仅影响预览垂直定位。
    }
    setState(() => _phase = _LiftPhase.opening);
    _master.duration = _kOpenDuration;
    _master.forward(from: 0);
  }
  /// 预览目标矩形:按源图宽高比放大到多限约束内,水平居中,
  /// 垂直居中于「顶部安全区 ~ 面板上缘」的可用区间
  /// (iOS 上下文菜单:预览悬于中上部,菜单贴底)。
  Rect _computeTargetRect(Size screen, EdgeInsets padding) {
    final aspect = _contentAspect;
    final maxW = math.min(
      screen.width - 2 * _kPreviewMarginH,
      _kPreviewMaxWidth,
    );
    final maxH = screen.height * _kPreviewMaxHeightFactor;
    var w = maxW;
    var h = w / aspect;
    if (h > maxH) {
      h = maxH;
      w = h * aspect;
    }
    final availTop = padding.top + 12;
    final availBottom = screen.height - _panelHeight - 16;
    final center = (availTop + availBottom) / 2;
    var top = center - h / 2;
    // 上下边界钳制:极端比例(矮窗口 + 高面板)下也不越出屏幕。
    if (top < availTop) top = availTop;
    final maxTop = math.max(availTop, availBottom - h);
    if (top > maxTop) top = maxTop;
    return Rect.fromLTWH((screen.width - w) / 2, top, w, h);
  }

  void _onMasterStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    switch (_phase) {
      case _LiftPhase.opening:
        if (mounted) setState(() => _phase = _LiftPhase.open);
      case _LiftPhase.closing:
      case _LiftPhase.fading:
        _finish();
      case _LiftPhase.open:
      case _LiftPhase.waitingMeasure:
        break;
    }
  }

  void _finish() {
    // 先恢复源图再移除 overlay:回落动画末帧预览与源图像素级重合,
    // 同帧切换无感。淡出路径源图已在 [_runAction] 里提前恢复。
    if (identical(ImageLiftMenu._activeSource.value, widget.sourceContext)) {
      ImageLiftMenu._activeSource.value = null;
    }
    widget.onDismissed();
    _pendingCallback?.call();
    _pendingCallback = null;
  }

  /// 快捷键 surface(ESC)的关闭入口。
  void _requestClose() => _close();

  /// 点遮罩 / 收回:预览弹簧回落到源矩形,面板继续滑出。
  ///
  /// 源图已不在视口内(窗口大改后文档流重排把源图推出屏、轮播翻页、
  /// 列表回收)或已卸载时,飞回原位会把预览甩出屏幕 —— 改为原地淡出
  /// (iOS 上下文菜单源视图不可用时的消散语义)。
  void _close({double? fromDrag}) {
    if (_phase != _LiftPhase.open && _phase != _LiftPhase.opening) return;
    _dragReset.stop();
    if (_isSourceVisible()) {
      _frozenDrag = fromDrag ?? _dragOffset;
      _dragOffset = 0;
      setState(() => _phase = _LiftPhase.closing);
      _master.duration = _kCloseDuration;
      _master.forward(from: 0);
    } else {
      _frozenDrag = 0;
      _dragOffset = 0;
      setState(() => _phase = _LiftPhase.fading);
      _master.duration = _kFadeDuration;
      _master.forward(from: 0);
    }
  }

  /// 源图当前是否仍(至少部分)在视口内且未卸载。
  bool _isSourceVisible() {
    if (_sourceDetached || _sourceOffscreen) return false;
    final screen = MediaQuery.sizeOf(context);
    return _sourceRect.overlaps(Offset.zero & screen);
  }

  /// 选动作:整体淡出(X/iOS 语义:选动作不回弹,直接消散),
  /// overlay 移除后执行回调。
  void _runAction(VoidCallback onTap) {
    if (_phase != _LiftPhase.open && _phase != _LiftPhase.opening) return;
    HapticFeedback.selectionClick();
    // 选动作整体淡出:源图立即在底下恢复(iOS 交叉淡出语义,遮罩与
    // 预览一起淡去时露出完整页面),动作在淡出完成后执行。
    if (identical(ImageLiftMenu._activeSource.value, widget.sourceContext)) {
      ImageLiftMenu._activeSource.value = null;
    }
    _pendingCallback = onTap;
    _frozenDrag = 0;
    _dragOffset = 0;
    _dragReset.stop();
    setState(() => _phase = _LiftPhase.fading);
    _master.duration = _kFadeDuration;
    _master.forward(from: 0);
  }

  void _handlePreviewTap() {
    final onTap = widget.onPreviewTap;
    if (onTap != null) {
      _runAction(onTap);
    } else {
      _close();
    }
  }

  void _onPanelDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta == 0) return;
    setState(() {
      _dragOffset = (_dragOffset + delta).clamp(0.0, _panelHeight);
    });
  }

  void _onPanelDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldClose =
        _dragOffset > _panelHeight * 0.32 || velocity > 700;
    if (shouldClose) {
      _close(fromDrag: _dragOffset);
      return;
    }
    if (_dragOffset > 0) {
      _dragResetAnim = Tween<double>(
        begin: _dragOffset,
        end: 0,
      ).animate(
        CurvedAnimation(parent: _dragReset, curve: Curves.easeOutCubic),
      );
      _dragReset.duration = const Duration(milliseconds: 260);
      _dragReset.forward(from: 0).whenCompleteOrCancel(() {
        if (mounted) setState(() => _dragOffset = 0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_master, _dragReset]),
      builder: (context, _) {
        final m = _master.value;
        final drag = _dragReset.isAnimating && _dragResetAnim != null
            ? _dragResetAnim!.value
            : _dragOffset;

        // 浮起进度(带微量过冲):opening 弹簧 0→1,closing 1→弹簧(0)。
        final double liftT;
        // 遮罩/阴影/模糊进度:快速淡入,收回时快速淡出。
        final double scrimT;
        // 面板位移(向下为正,px)。
        final double panelOffset;
        switch (_phase) {
          case _LiftPhase.waitingMeasure:
            liftT = 0;
            scrimT = 0;
            panelOffset = 0;
          case _LiftPhase.opening:
            final s = _spring.transform(m);
            liftT = s;
            scrimT = Curves.easeOut.transform(m);
            panelOffset = _panelHeight * (1 - s) + drag;
          case _LiftPhase.open:
            liftT = 1;
            scrimT = 1;
            panelOffset = drag;
          case _LiftPhase.closing:
            final s = _spring.transform(m);
            liftT = 1 - s;
            scrimT = 1 - Curves.easeOut.transform(m);
            // 从冻结的拖拽位继续滑出:起始即当前面板位置,无跳变。
            panelOffset = _frozenDrag + _panelHeight * s;
          case _LiftPhase.fading:
            liftT = 1;
            scrimT = 1 - m;
            panelOffset = drag;
        }

        // 目标矩形从当前 MediaQuery 派生:窗口尺寸变化触发本视图重建,
        // 同一帧即按新窗口算出落点;不经过任何回调链,无陈旧中间态。
        final mediaQuery = MediaQuery.of(context);
        final target = _phase == _LiftPhase.waitingMeasure
            ? null
            : _computeTargetRect(mediaQuery.size, mediaQuery.padding);
        final previewRect = target == null
            ? _sourceRect
            : Rect.lerp(_sourceRect, target, liftT)!;
        final radius = lerpDouble(
              widget.sourceRadius,
              _kPreviewTargetRadius,
              liftT,
            ) ??
            _kPreviewTargetRadius;

        Widget stack = Stack(
          children: [
            Positioned.fill(child: _buildScrim(context, scrimT)),
            Positioned.fromRect(
              rect: previewRect,
              child: _buildPreview(context, radius, scrimT, m),
            ),
            Positioned(
              left: 0,
              right: 0,
              // 测量前面板先移出屏外(Transform 不参与测量定位,直接
              // 用超大负 bottom 保证首帧不可见,布局尺寸不受影响)。
              bottom: _phase == _LiftPhase.waitingMeasure
                  ? -12000
                  : -panelOffset,
              child: _buildPanel(context),
            ),
          ],
        );

        if (_phase == _LiftPhase.fading) {
          stack = Opacity(opacity: 1 - m, child: stack);
        }

        return IgnorePointer(
          // 收回/淡出期间不再响应任何命中。
          ignoring: _phase == _LiftPhase.closing || _phase == _LiftPhase.fading,
          child: stack,
        );
      },
    );
  }

  /// 背景模糊 + 压暗(对齐 blur_config 的 Telegram 式口径与用户偏好)。
  Widget _buildScrim(BuildContext context, double scrimT) {
    if (scrimT <= 0) return const SizedBox.expand();
    final base = widget.enableBlur
        ? blurBarrierColor(Theme.of(context).brightness)
        : Colors.black54;
    final dim = ColoredBox(
      color: base.withValues(alpha: base.a * scrimT),
    );
    final tapArea = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _close,
      child: dim,
    );
    if (!widget.enableBlur) return tapArea;
    final sigma = (blurSigma * scrimT).clamp(0.01, blurSigma);
    return Semantics(
      label: S.current.common_close,
      button: true,
      child: BackdropFilter(
        filter: createBlurFilter(sigma),
        child: tapArea,
      ),
    );
  }

  /// 浮起的预览图:圆角 + 阴影随浮起渐显,内容零闪烁复用源图缓存。
  Widget _buildPreview(
    BuildContext context,
    double radius,
    double shadowT,
    double fadeT,
  ) {
    Widget preview = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.expand(child: Builder(builder: widget.previewBuilder)),
    );
    if (shadowT > 0) {
      preview = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.32 * shadowT),
              blurRadius: 44 * shadowT,
              offset: Offset(0, 14 * shadowT),
            ),
          ],
        ),
        child: preview,
      );
    }
    if (_phase == _LiftPhase.fading) {
      preview = Transform.scale(scale: 1 - 0.02 * fadeT, child: preview);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handlePreviewTap,
      child: preview,
    );
  }

  /// 底部动作面板:单行大图标按钮(iOS 16 上下文菜单/X 图片菜单与
  /// share sheet 同形态——动作多时横向滚动,绝不换行),外壳对齐
  /// AppSheetScaffold(surface 底、顶部圆角 20)。
  Widget _buildPanel(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 大屏限宽居中:面板两侧露出遮罩,点两侧同样可关闭(iOS 大屏形态)。
    final panel = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kPanelMaxWidth),
        child: Material(
          key: _panelKey,
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(_kPanelCornerRadius),
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
              // 单行横滚:X/iOS 动作面板形态。Row 收缩到内容宽:
              // 动作少时在面板内居中,多时横向滚动 + 渐隐边缘提示。
              child: FadingEdgeScrollView(
                fadeLeft: true,
                fadeRight: true,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final action in widget.actions)
                        _LiftActionButton(
                          action: action,
                          onTap: () => _runAction(action.onTap),
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
    final interactive = _phase == _LiftPhase.open;
    return GestureDetector(
      // 面板下拉跟手;常驻态以外的阶段不参与手势。
      onVerticalDragUpdate: interactive ? _onPanelDragUpdate : null,
      onVerticalDragEnd: interactive ? _onPanelDragEnd : null,
      child: panel,
    );
  }
}

/// 大图标动作按钮:60×60 圆角容器 + 下方小标签,
/// iOS 16 上下文菜单 / 分享建议行的按钮形态。
class _LiftActionButton extends StatelessWidget {
  const _LiftActionButton({required this.action, required this.onTap});

  final ImageLiftAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 76,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(action.icon, size: 26, color: colorScheme.onSurface),
              ),
              const SizedBox(height: 8),
              Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
