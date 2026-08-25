import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 一镜到底壳层(长按预览的容器变形):飞行壳(Material)从 [anchorRect]
/// (长按卡片的屏幕 rect)连续变形到内容最终 rect;内容自始至终嵌在壳
/// 内(OverflowBox 按目标宽布局、顶部对齐),裁剪窗随壳从卡片大小展开
/// —— 内容全程随壳飞行,没有"空壳移动"段;关闭沿同路径收回。
///
/// 使用方式:
/// - 路由:transitionBuilder 必须恒等(变形由本组件自驱,整页淡入会让
///   壳从透明浮现),transitionDuration 350ms;
/// - 弹窗 page 根返回本组件,animation 传路由 animation;
/// - 内容尺寸由 SizeChangedLayoutNotifier 实时上报:异步内容加载完成
///   壳自动跟随长高;反向收回时从内容当前实际尺寸飞回锚点。
///
/// 动画节奏(M3 容器变形规范):rect 走 spatial 弹簧(带过冲的落座感);
/// 圆角/颜色/阴影走 effects 曲线(临界阻尼,前半程收敛) —— 形状变化
/// 先于到达,避免"弹窗到位了圆角还在放大"。
class MorphingDialogShell extends StatefulWidget {
  const MorphingDialogShell({
    super.key,
    required this.animation,
    required this.anchorRect,
    required this.child,
    this.anchorColor,
    this.anchorRadius = 10,
    this.targetRadius = 20,
    this.dialogWidth,
    this.transitionDuration = const Duration(milliseconds: 350),
  });

  /// 路由 animation(正反向同一条空间曲线)
  final Animation<double> animation;

  /// 起点:长按卡片的屏幕 rect(已裁掉卡片底部间距)
  final Rect anchorRect;

  /// 内容柱(壳体 + 可能的底部操作面板),居中显示的最终布局
  final Widget child;

  /// 起点底色:卡片外壳底色,与弹窗壳 surface 做插值,起步无缝
  final Color? anchorColor;

  /// 起点圆角(卡片 10)
  final double anchorRadius;

  /// 终点圆角(弹窗 20)
  final double targetRadius;

  /// 内容布局宽;默认 (屏宽*0.9).clamp(300, 500)
  final double? dialogWidth;

  /// 弹簧曲线周期(与路由 transitionDuration 一致)
  final Duration transitionDuration;

  @override
  State<MorphingDialogShell> createState() => _MorphingDialogShellState();
}

class _MorphingDialogShellState extends State<MorphingDialogShell> {
  /// 内容柱的测量锚。框架禁止在 build 阶段读 Element.size,尺寸统一经
  /// [_scheduleSizeSync] 在 postFrame / 尺寸变化通知里写入;写入前壳
  /// 钳在锚点作蓄力起步
  final GlobalKey _contentKey = GlobalKey();
  Size? _contentSize;

  /// 弹簧曲线缓存:curveFor 的解析解含二分/log 预热,不能逐帧重建
  Curve? _spatialCurve;
  Curve? _effectsCurve;
  bool? _cachedM3e;

  @override
  void initState() {
    super.initState();
    // 首帧布局后尽快测得内容柱尺寸,让动画尽早起步
    // (路由插入帧 page 可能 offstage 不参与布局,故逐帧重试)
    _scheduleSizeSync();
  }

  void _ensureCurves(bool m3e) {
    if (_cachedM3e == m3e && _spatialCurve != null) return;
    _cachedM3e = m3e;
    // 空间属性(位置/尺寸):欠阻尼弹簧,带轻微过冲的落座感;
    // 效果属性(圆角/颜色/阴影/透明度):临界阻尼,不过冲
    _spatialCurve = m3e
        ? M3eMotion.defaultSpatial.curveFor(widget.transitionDuration)
        : Curves.easeInOutCubic;
    _effectsCurve = m3e
        ? M3eMotion.defaultEffects.curveFor(widget.transitionDuration)
        : Curves.easeInOut;
  }

  /// 内容尺寸变化(正文加载完成等)时安排重测,壳 rect 下一帧跟上
  bool _onContentSizeChanged(SizeChangedLayoutNotification notification) {
    _scheduleSizeSync();
    return true;
  }

  /// postFrame 里读 [_contentKey] 的布局尺寸写入 [_contentSize];
  /// 未布局(首帧 offstage 等)则逐帧重试直到测得
  void _scheduleSizeSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final render = _contentKey.currentContext?.findRenderObject();
      if (render is RenderBox && render.hasSize) {
        if (render.size != _contentSize) {
          setState(() => _contentSize = render.size);
        }
      } else {
        _scheduleSizeSync();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth =
        widget.dialogWidth ?? (screen.width * 0.9).clamp(300.0, 500.0);
    final anchor = widget.anchorRect;
    final anchorColor =
        widget.anchorColor ??
        theme.cardTheme.color ??
        theme.colorScheme.surfaceContainerLow;
    _ensureCurves(M3eFlags.of(context).enabled);

    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, contentBody) {
        final rawT = widget.animation.value;
        // 内容尺寸经 postFrame 测得前(至多前两帧)壳钳在锚点,作蓄力起步
        final size = _contentSize;
        final spatialT = size == null ? 0.0 : _spatialCurve!.transform(rawT);
        final effectsT = _effectsCurve!.transform(rawT);
        final dest = size == null
            ? anchor
            : Rect.fromLTWH(
                (screen.width - size.width) / 2,
                (screen.height - size.height) / 2,
                size.width,
                size.height,
              );
        final shellRect = Rect.lerp(anchor, dest, spatialT)!;
        // 起步快速淡入:柔化"卡片小标题 → 弹窗大标题"的换皮;
        // 收回沿同一曲线,末段内容渐隐、壳缩回卡片后无缝交还
        final contentOpacity = const Interval(
          0.0,
          0.22,
          curve: Curves.easeOut,
        ).transform(rawT);

        return Stack(
          children: [
            Positioned.fromRect(
              key: const ValueKey('morphing-shell'),
              rect: shellRect,
              child: Material(
                elevation: 8 * effectsT,
                borderRadius: BorderRadius.circular(
                  widget.anchorRadius +
                      (widget.targetRadius - widget.anchorRadius) * effectsT,
                ),
                clipBehavior: Clip.antiAlias,
                color: Color.lerp(
                  anchorColor,
                  theme.colorScheme.surface,
                  effectsT,
                ),
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minWidth: dialogWidth,
                  maxWidth: dialogWidth,
                  // 必须显式给 0:null 会继承父级 tight 约束(壳高),
                  // 内容被强制撑到壳高 → 测得的"内容高"失真自锁,
                  // 落座后壳比内容高出一截(底部空白)
                  minHeight: 0,
                  maxHeight: screen.height,
                  child: Opacity(
                    opacity: contentOpacity,
                    child: IgnorePointer(
                      // 飞行期间不响应指针,落座后才开放交互
                      ignoring: rawT < 1.0,
                      child: contentBody!,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      // 尺寸监听挂在 AnimatedBuilder 的常量 child 上,只建一次,
      // 不随动画逐帧重建
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: _onContentSizeChanged,
        child: SizeChangedLayoutNotifier(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: screen.height * 0.7),
            child: KeyedSubtree(key: _contentKey, child: widget.child),
          ),
        ),
      ),
    );
  }
}
