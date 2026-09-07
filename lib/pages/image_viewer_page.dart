import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../services/discourse_cache_manager.dart';
import '../services/dynamic_content_suspension_service.dart';
import '../services/image_decode_spec_memo.dart';
import '../utils/double_tap_zoom_controller.dart';
import '../utils/hero_visibility_controller.dart';
import '../utils/image_save_utils.dart';
import '../utils/screenshot_utils.dart';
import '../utils/svg_utils.dart';
import '../widgets/content/animated_svg_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../services/toast_service.dart';
import '../utils/platform_utils.dart';
import '../utils/share_utils.dart';
import '../widgets/common/app_bottom_sheet.dart';
import '../widgets/common/hero_image.dart';
import '../widgets/common/image_context_menu.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../l10n/s.dart';

class ImageViewerPage extends ConsumerStatefulWidget {
  final String? imageUrl;
  final Uint8List? imageBytes;
  final String? heroTag;
  final List<String>? galleryImages;

  /// 每张图片对应的 Hero tag 列表，用于切换图片后正确返回
  final List<String>? heroTags;
  final int initialIndex;
  final bool enableShare;

  /// 缩略图 URL，加载原图时先显示缩略图避免闪烁
  final String? thumbnailUrl;

  /// 画廊中每张图片的缩略图 URL 列表
  final List<String>? thumbnailUrls;

  /// 画廊中每张图片的文件名列表
  final List<String?>? filenames;

  /// 源缩略图的 BoxFit(仅 cover 时启用飞行 crossfade:源瓦片是裁剪
  /// 展示,起飞/落地瞬间与查看器的 contain 之间有跳变,飞行层用
  /// cover 纹理短暂淡入淡出盖住差异)。null = 源与查看器同为 contain。
  final BoxFit? heroSourceFit;

  /// 源缩略图的圆角(飞行中插值到 0 / 从 0 恢复)
  final double heroSourceRadius;

  /// 源为圆形裁切(头像):飞行中圆形↔直角连续插值
  final bool heroSourceCircular;

  const ImageViewerPage({
    super.key,
    this.imageUrl,
    this.imageBytes,
    this.heroTag,
    this.galleryImages,
    this.heroTags,
    this.initialIndex = 0,
    this.enableShare = false,
    this.thumbnailUrl,
    this.thumbnailUrls,
    this.filenames,
    this.heroSourceFit,
    this.heroSourceRadius = 0,
    this.heroSourceCircular = false,
  }) : assert(imageUrl != null || imageBytes != null);

  /// 查看器路由的黑底/整页淡入淡出曲线:与 Hero 飞行(吃路由原始
  /// animation,全程 300ms)异速 —— push 前 60%(~180ms)完成淡入、
  /// pop 前 60% 完成淡出(reverseCurve 的 t 轴仍是 parent 值,
  /// Interval(0.4,1.0) 即 parent 1→0.4 期间完成 1→0),背景先立住/
  /// 先退场,图片随后落位/飞回,分层感更自然。
  ///
  /// **必须跨帧持有,不能每帧新建**(故有 [_RouteFade] 这层壳):
  /// [CurvedAnimation] 用跨帧字段 `_curveDirection` 记住「进入动画时
  /// 的方向」,`_curveDirection ?? status` 在动画中途保留旧方向,正是
  /// 上游用来「换向不跳变」的机制;而构造函数拿**当帧 status** 初始化
  /// 它。_ModalScopeState 用 ListenableBuilder 监听路由动画,转场树
  /// **每帧重建**,所以在 transitionsBuilder 里 new 一份 = 每帧把方向
  /// 记忆抹成当帧值 = 机制失效。
  ///
  /// 配上这里前后不对称的区间,后果是 Hero 飞行未结束就关闭时,同一帧
  /// parent 值不变而 alpha 断崖:实测 parent 恒为 0.427,alpha 0.879 →
  /// 0.004(reverseCurve 的 Interval(0.4,1.0) 在 0.427 处几乎为 0)。
  /// 观感即「整页黑底瞬间消失、底页全露,图片却还在飞」的黑闪。
  static CurvedAnimation _buildRouteFade(Animation<double> animation) {
    return CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      reverseCurve: const Interval(0.4, 1.0, curve: Curves.easeIn),
    );
  }

  /// 仅供测试:查看器实际使用的淡入淡出层(黑闪回归防线)。
  /// 走真 widget 而非只取曲线 —— 否则测不到「跨帧持有」这个关键点。
  @visibleForTesting
  static Widget debugRouteFade({
    required Animation<double> animation,
    required Widget child,
  }) => _RouteFade(animation: animation, child: child);

  /// 仅供测试:退场飞行起点的发布判据(见 [_ImageViewerPageState.
  /// _publishExitFlightRect])。读真实现,不复刻判据。
  @visibleForTesting
  static bool debugIsDisplacedFromBaseline(Rect? rect, Rect? baseline) =>
      _ImageViewerPageState._isDisplacedFromBaseline(rect, baseline);

  /// 仅供测试:放大态可见窗口的归一化算式(读真实现)。
  @visibleForTesting
  static Rect? visibleFractionOf(Rect imageRect, Size viewport) =>
      _ImageViewerPageState.visibleFractionOf(imageRect, viewport);

  /// 仅供测试:飞行体该用真实进度还是钉在 1。
  ///
  /// 放大态必须用真实进度,否则取景框永不张开 —— contain 源(轮播/正文)
  /// 一直走的就是钉住分支,所以放大后返回全程停在局部视图。
  @visibleForTesting
  static bool debugFlightNeedsProgress({
    required bool coverSource,
    required bool zoomed,
  }) => coverSource || zoomed;

  /// 初始页缩略图选择规则。公开给测试，避免回归成画廊汇总 URL 覆盖
  /// 点击入口实际显示 URL 的旧行为。
  @visibleForTesting
  static String? debugThumbnailUrlForIndex({
    required int index,
    required int initialIndex,
    String? thumbnailUrl,
    List<String>? thumbnailUrls,
  }) {
    if (index == initialIndex && thumbnailUrl != null) return thumbnailUrl;
    if (thumbnailUrls != null && index < thumbnailUrls.length) {
      return thumbnailUrls[index];
    }
    return null;
  }

  /// 使用透明路由打开图片查看器。返回的 Future 在查看器关闭时完成
  /// (调用方可借此恢复被隐藏的浮层等)。
  static Future<void> open(
    BuildContext context,
    String imageUrl, {
    String? heroTag,
    List<String>? galleryImages,
    List<String>? heroTags,
    int initialIndex = 0,
    bool enableShare = false,
    String? thumbnailUrl,
    List<String>? thumbnailUrls,
    List<String?>? filenames,
    BoxFit? heroSourceFit,
    double heroSourceRadius = 0,
    bool heroSourceCircular = false,
  }) {
    // Hero 飞行是框架级硬条件:只发生在同一 Navigator 的两个 PageRoute
    // 之间(HeroController._maybeStartHeroTransition 对非 PageRoute 直接
    // 返回)。从弹窗(PopupRoute,如通知页面弹窗/用户卡片)里打开时
    // from 端不是 PageRoute,飞行永远不启动——但查看器拿着 heroTag 会
    // 走"配对 Hero"的开合/退场路径(禁用缩放预览、退场等归位飞行),
    // 表现为闪烁/贴片静止。此时一律退化为纯淡入淡出(缩略图占位仍然
    // 生效,只是不飞)。
    if (ModalRoute.of(context) is! PageRoute) {
      heroTag = null;
      heroTags = null;
    }
    return Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return ImageViewerPage(
            imageUrl: imageUrl,
            heroTag: heroTag,
            galleryImages: galleryImages,
            heroTags: heroTags,
            initialIndex: initialIndex,
            enableShare: enableShare,
            thumbnailUrl: thumbnailUrl,
            thumbnailUrls: thumbnailUrls,
            filenames: filenames,
            heroSourceFit: heroSourceFit,
            heroSourceRadius: heroSourceRadius,
            heroSourceCircular: heroSourceCircular,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            buildPredictiveBackPageTransitions(
              context,
              animation,
              secondaryAnimation,
              child,
              // 透明路由用 fade:滑出对「下方要透出内容」的查看器没有
              // 意义。手势期同样是这个 fade(由手势进度驱动),与按钮
              // 返回一致 —— 单一分支原则。
              transitionBuilder: (_, animation, _, child) =>
                  _RouteFade(animation: animation, child: child),
            ),
      ),
    );
  }

  /// 打开内存图片查看器
  static void openBytes(BuildContext context, Uint8List bytes) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return ImageViewerPage(imageBytes: bytes);
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            buildPredictiveBackPageTransitions(
              context,
              animation,
              secondaryAnimation,
              child,
              transitionBuilder: (_, animation, _, child) =>
                  _RouteFade(animation: animation, child: child),
            ),
      ),
    );
  }

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

/// 承载查看器整页淡入淡出的壳:唯一职责是**跨帧持有那一份
/// [CurvedAnimation]**,见 [ImageViewerPage._buildRouteFade] 的说明。
///
/// 转场树每帧重建,但同一路由的 [animation] 对象恒定,故本 State 只在
/// animation 换了对象时才重建曲线(didUpdateWidget),其余帧一直复用同
/// 一份 —— `_curveDirection` 得以跨帧存活,换向不再断崖。
class _RouteFade extends StatefulWidget {
  const _RouteFade({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<_RouteFade> createState() => _RouteFadeState();
}

class _RouteFadeState extends State<_RouteFade> {
  late CurvedAnimation _opacity;

  @override
  void initState() {
    super.initState();
    _opacity = ImageViewerPage._buildRouteFade(widget.animation);
  }

  @override
  void didUpdateWidget(_RouteFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.animation, widget.animation)) {
      _opacity.dispose();
      _opacity = ImageViewerPage._buildRouteFade(widget.animation);
    }
  }

  @override
  void dispose() {
    // CurvedAnimation 在 parent 上挂了 status 监听,不摘会一直吊着路由动画
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with TickerProviderStateMixin, DoubleTapZoomMixin {
  late int currentIndex;
  bool _isSaving = false;
  bool _isSharing = false;
  bool _showUI = true;
  late final DynamicContentSuspensionLease _dynamicContentLease;

  /// 通知所有缓存页面当前活跃的 Hero 页码变化，确保只有当前页有 Hero
  late final ValueNotifier<int> _activeHeroPage;

  /// 画廊翻页控制器。必须是 State 字段:内联在 build 里会导致每次
  /// setState(如 onPageChanged、_toggleUI)都新建 controller,切页
  /// 动画中途换控制器。
  ExtendedPageController? _galleryPageController;

  ExtendedPageController get _ensureGalleryPageController =>
      _galleryPageController ??= ExtendedPageController(
        initialPage: widget.initialIndex,
        pageSpacing: 50,
      );

  /// 手势状态控制器(按页索引;单图/内存图用 0)。生命周期由本 State
  /// 持有 —— loading→completed 等树切换只换绘制载体,手势状态与进行
  /// 中的交互(如下滑关闭)不再随载体销毁。
  final Map<int, ImageGestureController> _gestureControllers = {};

  /// 退场缩放处理。缩放是 RawGestureImage 的画布级变换,Hero 飞行只
  /// 收缩布局盒子,两者叠加会闪烁(飞行中内容乱跳+落地突变),故飞行
  /// 起跳前缩放必须回到 1.0 contain。两条路径:
  /// - 按钮/程序化 pop:reverse 首帧瞬时归位(无进度可跟,跳变弱);
  /// - 预测返回/iOS 拖拽:手势进度驱动**松弛** —— 认领后路由动画值
  ///   即 1-进度,把 scale/offset 按 animation.value 从起始态 lerp 到
  ///   contain。拖越多收越拢;cancel 时动画弹回 1.0,同一 lerp 自动
  ///   恢复原缩放;commit 时残余 snap 到 1.0 再起飞。
  ModalRoute<dynamic>? _route;
  ValueListenable<bool>? _navUserGesture;

  ImageGestureController _obtainGestureController(
    int index, {
    required bool inPageView,
    double maxScale = 4.0,
    double animationMaxScale = 4.5,
  }) {
    return _gestureControllers.putIfAbsent(
      index,
      () => ImageGestureController(
        config: GestureConfig(
          minScale: 0.9,
          animationMinScale: 0.7,
          maxScale: maxScale,
          animationMaxScale: animationMaxScale,
          speed: 1.0,
          inertialSpeed: 500.0,
          initialScale: 1.0,
          inPageView: inPageView,
          initialAlignment: InitialAlignment.center,
        ),
      ),
    );
  }

  /// 获取指定索引的 hero tag
  String? _getHeroTagForIndex(int index) {
    if (widget.heroTags != null && index < widget.heroTags!.length) {
      return widget.heroTags![index];
    } else if (index == widget.initialIndex && widget.heroTag != null) {
      return widget.heroTag;
    }
    return null;
  }

  /// 构建查看器侧 Hero(单图/画廊共用)。
  ///
  /// 飞行体一律用 [CoverContainFlightImage](自绘 drawImageRect,画的是干净
  /// 的缩略图位图),**不用查看器的 child**。child 是 `GestureImageView` 的
  /// 绘制层,带画布级变换(缩放/平移),塞进逐帧收缩的飞行盒子里不会重新
  /// 适配,于是画面被裁切 —— 用户所见「轮播尾帧尺寸对了,但图是裁切的」。
  ///
  /// 两种来源的插值口径:
  /// - cover 源(网格瓦片/圆形头像):裁切窗口随 progress 从 cover 张到
  ///   contain,两端与真实内容像素级对齐;
  /// - contain 源(轮播/正文单图):两端都是 contain,只有盒子比例在变,故把
  ///   t 钉在 1(`kAlwaysCompleteAnimation`)—— 恒取全图、按真实比例 contain
  ///   进当前飞行盒子。缩放由 Hero 盒子逐帧收缩承担,故观感是「完整大图随
  ///   Hero 动画连续变小」,不是先跳一下再播。
  ///
  /// push 方向本 shuttle 生效(toHero=查看器优先);pop 方向源端
  /// HeroImage 的 shuttle 生效(带同款裁切插值),双向一致。
  Widget _buildViewerHero({
    required String tag,
    required String? thumbUrl,
    required Widget child,
  }) {
    final bool coverSource =
        widget.heroSourceFit == BoxFit.cover || widget.heroSourceCircular;
    // 自绘飞行体需要一个位图源;没有缩略图只能退回 child
    final bool useFlightImage = thumbUrl != null;
    return Hero(
      tag: tag,
      // 预测返回是 user gesture 转场,不开这个标记 Hero 不飞
      // (与所有源端 Hero 配对开启,见 hero_image/discourse_image 等)
      transitionOnUserGestures: true,
      flightShuttleBuilder: !useFlightImage
          ? (_, _, _, _, _) => child
          : (flightContext, animation, direction, fromContext, toContext) {
              // animation 为路由原始动画,值语义恒为「0=贴源,1=在查看器」。
              //
              // 何时需要 src 窗口随飞行插值:
              // - cover 源(网格瓦片/圆形头像):源端是裁切展示,窗口要从
              //   cover 张到 contain;
              // - **放大态**(任何源):取景框要从「此刻看得见的那块」张回
              //   完整图。这里若钉在 1,窗口永不张开 ⇒ 飞行全程都是放大态的
              //   局部视图、落地才忽然完整(用户报的症状,contain 源尤其明显
              //   因为它一直走的就是钉住分支)。
              //
              // 其余(contain 源且未放大)钉在 1:两端都是完整图,只有盒子
              // 比例在变,插值反而引入不必要的窗口动画。
              final zoomed =
                  HeroVisibilityController.instance.exitVisibleFraction != null;
              // 判据抽成 ImageViewerPage.debugFlightNeedsProgress —— 产品
              // 代码与测试读**同一个**实现,避免测试复刻逻辑变成自洽装置。
              final needsProgress = ImageViewerPage.debugFlightNeedsProgress(
                coverSource: coverSource,
                zoomed: zoomed,
              );
              // 源端缩略图盒子的固定宽高比:push 时源在 from,pop(divert)时
              // 沿用 push 建的 shuttle 仍是 from。cover 裁窗须按它算,不按飞行
              // 途中变化的画布比例(否则两端完整、中间帧被裁,见
              // CoverContainFlightImage.sourceAspect)。
              final BuildContext srcContext =
                  direction == HeroFlightDirection.pop
                  ? toContext
                  : fromContext;
              double? sourceAspect;
              final ro = srcContext.findRenderObject();
              if (ro is RenderBox && ro.hasSize && ro.size.height > 0) {
                sourceAspect = ro.size.width / ro.size.height;
              }
              return CoverContainFlightImage(
                image: _thumbnailProvider(thumbUrl),
                animation: needsProgress ? animation : kAlwaysCompleteAnimation,
                radius: widget.heroSourceRadius,
                circular: widget.heroSourceCircular,
                // 贴源端窗口按源端展示方式算:cover 裁切展示时要与源端
                // Image(fit:cover) 的可见区域对齐,否则落地瞬间「裁切一条」
                // 突变成完整图(聊天气泡因 clamp 夹高最明显)
                coverSource: coverSource,
                sourceAspect: sourceAspect,
                fallback: child,
              );
            },
      child: child,
    );
  }

  /// 查看器主图解码上限:等比 clamp 到屏幕长边×3(且 ≤8192,常见 GPU
  /// 纹理上限)。只有病态大图(8K 级手机直出原图)会被降采样 —— 全尺寸
  /// 解码这类图会产生 100ms+ 的同步纹理上传,独占 raster 线程期间全 app
  /// 掉帧(诊断实测单帧 raster 148ms、后续帧排队 300ms)。maxScale 4.0
  /// 的放大浏览下该上限内清晰度无感知差异。
  ImageProvider _clampedViewerProvider(String url) {
    final view = View.of(context);
    final longestPx = (view.physicalSize.longestSide * 3)
        .clamp(2048.0, 8192.0)
        .round();
    return ResizeImage(
      discourseImageProvider(
        url,
        bucket: BlobImageCache.originalBucket,
        // 用户主动点开的大图,插到所有预建/预取前面
        priority: DownloadPriority.high,
      ),
      width: longestPx,
      height: longestPx,
      policy: ResizeImagePolicy.fit,
    );
  }

  /// 缩略图占位 provider:按帖内登记的解码参数原样重建 —— ImageCache 的
  /// key 是 ResizeImageKey(内层 key + 宽高 + 策略),参数一致才能同步命中
  /// 帖内那份还在屏的解码位图;裸 provider 是不同 key,Hero 转场帧会白付
  /// 一次全量解码(原图 jpg/png 尤其疼)。未登记(非帖内入口)退回裸
  /// provider,行为同旧。
  ImageProvider _thumbnailProvider(String url) {
    // 头像 URL 走 avatarBucket:与页面头像(SmartAvatar)同 bucket 同
    // key,占位/飞行纹理直接命中已解码缓存(否则 content bucket 视为
    // 全新资源,首次飞行拿不到纹理退化为无插值)
    if (url.contains('/user_avatar/')) {
      return discourseImageProvider(url, bucket: BlobImageCache.avatarBucket);
    }
    final spec = ImageDecodeSpecMemo.peek(url);
    if (spec == null) return discourseImageProvider(url);
    return ResizeImage(
      discourseImageProvider(url),
      width: spec.$1,
      height: spec.$2,
      policy: ResizeImagePolicy.fit,
    );
  }

  /// 下滑关闭判定:惯性投影终点法。
  ///
  /// projected = 当前位移 + v · k(k = r/(1-r)/1000 ≈ 0.199,r=0.995/ms
  /// 的指数衰减投影系数)—— 用"松手后惯性预测能滑到哪"代替"松手瞬间
  /// 在哪"。慢拖(v≈0)时投影≈位移,与旧的纯位移阈值行为一致;快甩时
  /// 投影提前过阈值,轻扫即可关闭;拖下又反向甩回时投影回落,自然回弹。
  /// 阈值维持 defaultSlideEndHandler 的 1/6 不变。
  bool _slideShouldPop(
    Offset offset,
    ScaleEndDetails details,
    Size pageSize,
    SlideAxis axis,
  ) {
    const double k = 0.199;
    final Offset v = details.velocity.pixelsPerSecond;
    if (axis == SlideAxis.vertical) {
      return (offset.dy + v.dy * k).abs() > pageSize.height / 6;
    }
    // both:向量投影,阈值与 defaultSlideEndHandler both 分支一致
    final Offset projected = offset + v * k;
    return projected.distance >
        Offset(pageSize.width, pageSize.height).distance / 6;
  }

  @override
  void initState() {
    super.initState();
    // 图片查看器使用透明路由，底层页面仍会保持可见和Ticker活跃。
    // 查看大图期间暂停帖子动态内容，避免SVG动画与大图解码/缩放争抢
    // UI、raster和GPU；关闭查看器后由租约自动恢复。
    _dynamicContentLease = DynamicContentSuspensionService.instance.acquire(
      reason: 'image-viewer',
    );
    currentIndex = widget.initialIndex;
    _activeHeroPage = ValueNotifier(currentIndex);
    // 初始化双击缩放
    initDoubleTapZoom();
    // 预加载相邻图片
    _preloadAdjacentImages();
    // 静默设置初始隐藏的图片（不触发通知，因为此时可能正在构建）
    HeroVisibilityController.instance.setHiddenTagSilent(
      _getHeroTagForIndex(currentIndex),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_onRouteAnimationStatus);
      _route = route;
      _route?.animation?.addStatusListener(_onRouteAnimationStatus);
    }
    final userGesture = route?.navigator?.userGestureInProgressNotifier;
    if (!identical(userGesture, _navUserGesture)) {
      _navUserGesture?.removeListener(_onNavUserGestureChanged);
      _navUserGesture = userGesture;
      _navUserGesture?.addListener(_onNavUserGestureChanged);
    }
  }

  /// 退场起点(按钮/程序化 pop):路由动画转 reverse 的第一帧,早于
  /// HeroController 对 to 路由的测量与飞行起跳。
  ///
  /// 这里必须**同时**宣告 startPopping:它原先挂在源端
  /// flightShuttleBuilder 的 pop 分支里,而 push 飞行未跑完就被 pop 打断
  /// 时框架走 divert 且不重建 shuttle,那个监听器根本不会注册 ⇒ 源端
  /// 缩略图 Opacity 锁死在 0 ⇒ 飞行体撤走瞬间是空洞(黑闪)。详见
  /// [HeroVisibilityController.startPopping]。
  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.reverse) return;
    _publishExitFlightRect();
    HeroVisibilityController.instance.startPopping();
  }

  /// 退场起点(预测返回/iOS 拖拽):手势置位即发布飞行矩形(早于
  /// HeroController 测量飞行几何)。手势期不改动缩放 —— 缩放由 Hero
  /// 飞行承载。同样要宣告 startPopping,理由同上。
  void _onNavUserGestureChanged() {
    if (_navUserGesture?.value == true && (_route?.isCurrent ?? false)) {
      _publishExitFlightRect();
      HeroVisibilityController.instance.startPopping();
    }
  }

  /// 把「当前页图片在屏幕上的可见矩形」发布给源端 Hero 作飞行起点。
  ///
  /// destinationRect 是画布级变换后的目标矩形(含缩放与平移),坐标系为
  /// 查看器绘制层的局部坐标;查看器是全屏路由,局部原点即屏幕原点,可
  /// 直接当全局矩形用。
  ///
  /// **判据必须是「矩形是否偏离 contain 基线」,不能用 totalScale > 1**。
  /// totalScale 的 1.0 不代表"贴合屏幕":双击缩放的智能档位会把小图算出
  /// >1 的比例(`_calculateSmartScale`:正方形图在 1212x758 屏上得
  /// 1212/758 ≈ 1.6),之后即使视觉上看着没放大,totalScale 仍停在 1.6。
  /// 真机实测:500x500 的图、用户没主动放大,却发布了 1212x1212 的矩形
  /// (contain 基线本应是 758x758,且它上下各溢出屏幕 191px)—— 拿它当
  /// 飞行起点,观感就是「大图先跳成另一个尺寸,再从那儿播动画」。
  ///
  /// rawDestinationRect 是缩放前的 contain 基线(见 extended_image_lite
  /// 的 `calculateFinalDestinationRect`),两者近似相等即视为未偏离,
  /// 发布 null 走 Hero 默认的布局盒子几何。
  void _publishExitFlightRect() {
    final details = _gestureControllers[currentIndex]?.details;
    final rect = details?.destinationRect;
    final baseline = details?.rawDestinationRect;
    final displaced = _isDisplacedFromBaseline(rect, baseline);
    final ctrl = HeroVisibilityController.instance;
    ctrl.setExitFlightRect(displaced ? rect : null);
    // 一并发布「此刻看得见的那部分图」:只喂盒子不够,飞行体还要靠它把
    // 取景框张回完整图。详见 HeroVisibilityController.exitVisibleFraction。
    ctrl.setExitVisibleFraction(
      displaced ? visibleFractionOf(rect!, MediaQuery.sizeOf(context)) : null,
    );
  }

  /// 把「整张图在屏上占据的矩形」与视口求交,换算成**相对全图的归一化窗口**。
  ///
  /// [imageRect] 放大后通常大于屏幕、原点为负;与视口的交集即用户此刻真正
  /// 看得见的那块;再除以 imageRect 自身尺寸得 0~1 比例 —— 飞行体拿它当 src
  /// 窗口起点,无需知道任何像素尺寸或缩放倍率。
  ///
  /// 画面完全落在视口内(未被裁切)时返回 null:此时可见即完整图,飞行体
  /// 维持原有口径。
  @visibleForTesting
  static Rect? visibleFractionOf(Rect imageRect, Size viewport) {
    if (imageRect.isEmpty || !imageRect.isFinite) return null;
    final visible = imageRect.intersect(Offset.zero & viewport);
    if (visible.isEmpty || !visible.isFinite) return null;
    final f = Rect.fromLTRB(
      (visible.left - imageRect.left) / imageRect.width,
      (visible.top - imageRect.top) / imageRect.height,
      (visible.right - imageRect.left) / imageRect.width,
      (visible.bottom - imageRect.top) / imageRect.height,
    );
    // 几乎就是完整图 ⇒ 没被裁切,不必插值
    const eps = 0.01;
    if (f.left <= eps &&
        f.top <= eps &&
        f.right >= 1 - eps &&
        f.bottom >= 1 - eps) {
      return null;
    }
    return f;
  }

  /// 可见矩形是否已偏离 contain 基线(= 用户真的缩放/平移过)。
  /// 容差 1px:浮点与像素对齐带来的微差不算偏离。
  static bool _isDisplacedFromBaseline(Rect? rect, Rect? baseline) {
    if (rect == null || rect.isEmpty || !rect.isFinite) return false;
    // 拿不到基线时保守处理:不发布,退回框架默认几何(旧行为)
    if (baseline == null || baseline.isEmpty || !baseline.isFinite) {
      return false;
    }
    const tolerance = 1.0;
    return (rect.left - baseline.left).abs() > tolerance ||
        (rect.top - baseline.top).abs() > tolerance ||
        (rect.width - baseline.width).abs() > tolerance ||
        (rect.height - baseline.height).abs() > tolerance;
  }

  @override
  void dispose() {
    HeroVisibilityController.instance.setExitFlightRect(null);
    _route?.animation?.removeStatusListener(_onRouteAnimationStatus);
    _navUserGesture?.removeListener(_onNavUserGestureChanged);
    _dynamicContentLease.release();
    HeroVisibilityController.instance.clear();
    _activeHeroPage.dispose();
    _galleryPageController?.dispose();
    for (final controller in _gestureControllers.values) {
      controller.dispose();
    }
    _restoreSystemUI();
    disposeDoubleTapZoom();
    super.dispose();
  }

  void _toggleUI() {
    setState(() {
      _showUI = !_showUI;
    });
    _updateSystemUI();
  }

  /// 显示图片长按菜单（不含「查看大图」，因为已在查看页内）
  void _showContextMenu(BuildContext context, {Offset? position}) {
    ImageContextMenu.show(
      context: context,
      imageUrl: _currentImageUrl,
      showViewFullImage: false,
      fileName: _currentFilename,
      position: position,
      onClose: () => Navigator.of(context).pop(),
    );
  }

  void _hideUI() {
    if (!_showUI) return;
    setState(() {
      _showUI = false;
    });
    _updateSystemUI();
  }

  void _updateSystemUI() {
    if (_showUI) {
      _restoreSystemUI();
    } else {
      // 用 immersiveSticky 而非 manual+overlays:[]。
      // Android 15+ 默认 edge-to-edge，manual 模式会被系统忽略导致隐藏后
      // 无法恢复。immersiveSticky 是专为 fullscreen 设计的模式，Android 15+
      // 仍正常工作，且边缘上滑可临时显示 system bars。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Future<void> _restoreSystemUI() async {
    // Flutter 3.41+ 引擎在 setSystemChromeEnabledSystemUIMode 的 EDGE_TO_EDGE
    // 分支不清除前一个模式（immersiveSticky）设的 SYSTEM_UI_FLAG_FULLSCREEN
    // 和 SYSTEM_UI_FLAG_HIDE_NAVIGATION，导致直接切 edgeToEdge 不能恢复 bars。
    //
    // 解决：先走 manual+all overlays 路径（对应 setSystemChromeEnabledSystemUIOverlays），
    // 该路径会显式清除上述 immersive flags 并显示 bars；然后再切回 edgeToEdge
    // 恢复全局 edge-to-edge 布局。
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 预加载相邻图片
  void _preloadAdjacentImages() {
    final images = widget.galleryImages;
    if (images == null || images.length <= 1) return;

    final preloadUrls = <String>[];
    // 预加载前一张和后一张
    if (currentIndex > 0) {
      preloadUrls.add(images[currentIndex - 1]);
    }
    if (currentIndex < images.length - 1) {
      preloadUrls.add(images[currentIndex + 1]);
    }
    for (final url in preloadUrls) {
      unawaited(BlobImageCache.precache(BlobImageCache.originalBucket, url));
    }
  }

  /// 获取当前显示的图片 URL
  String get _currentImageUrl {
    final images = widget.galleryImages ?? [widget.imageUrl!];
    return images[currentIndex];
  }

  /// 获取当前图片的文件名
  String? get _currentFilename {
    final filenames = widget.filenames;
    if (filenames == null) return null;
    if (currentIndex < filenames.length) return filenames[currentIndex];
    return null;
  }

  /// 保存当前图片（移动端进相册、桌面端另存为文件）
  Future<void> _saveCurrentImage() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      // 使用缓存管理器获取图片字节（优先从缓存读取）
      final imageUrl = _currentImageUrl;
      final Uint8List imageBytes = await BlobImageCache.fetch(
        BlobImageCache.originalBucket,
        imageUrl,
      );

      if (imageBytes.isEmpty) {
        throw Exception(S.current.image_fetchFailed);
      }

      // 命名与分享同口径（原始文件名优先，回退时间戳）；
      // 落点与提示由 ImageSaveUtils 按平台统一处理。
      final ext = BlobImageCache.httpUrlExtension(imageUrl);
      final name =
          ShareUtils.safeFileBaseName(_currentFilename) ??
          'fluxdo_${DateTime.now().millisecondsSinceEpoch}';
      await ImageSaveUtils.saveBytes(imageBytes, fileName: '$name.$ext');
    } catch (e) {
      debugPrint('Save image error: $e');
      if (mounted) {
        ToastService.showError(S.current.imageViewer_saveFailedRetry);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// 保存内存图片（移动端进相册、桌面端另存为文件）
  Future<void> _saveMemoryImage() async {
    if (_isSaving || widget.imageBytes == null) return;
    setState(() => _isSaving = true);
    try {
      await ImageSaveUtils.saveBytes(
        widget.imageBytes!,
        fileName: 'fluxdo_${DateTime.now().millisecondsSinceEpoch}.png',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 复制内存图片到剪贴板
  Future<void> _copyMemoryImage() async {
    final bytes = widget.imageBytes;
    if (bytes == null || bytes.isEmpty) return;
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        ToastService.showError(S.current.common_clipboardUnavailable);
        return;
      }
      final item = DataWriterItem();
      item.add(Formats.png(bytes));
      await clipboard.write([item]);
      if (mounted) ToastService.showSuccess(S.current.image_copied);
    } catch (e) {
      debugPrint('[ImageViewerPage] copyMemoryImage error: $e');
      if (mounted) ToastService.showError(S.current.image_copyFailed);
    }
  }

  /// 分享内存图片
  Future<void> _shareMemoryImage() async {
    final bytes = widget.imageBytes;
    if (bytes == null || bytes.isEmpty) return;
    try {
      await ScreenshotUtils.shareImage(bytes);
    } catch (e) {
      debugPrint('[ImageViewerPage] shareMemoryImage error: $e');
      if (mounted) ToastService.showError(S.current.common_shareFailed);
    }
  }

  /// 内存图片的长按 / 右键菜单（保存 / 复制 / 分享）
  void _showBytesContextMenu(BuildContext context, {Offset? position}) {
    if (widget.imageBytes == null) return;

    if (PlatformUtils.isDesktop && position != null) {
      final overlayRenderObject = Overlay.of(
        context,
      ).context.findRenderObject();
      if (overlayRenderObject is RenderBox && overlayRenderObject.hasSize) {
        final relativeRect = RelativeRect.fromRect(
          position & Size.zero,
          Offset.zero & overlayRenderObject.size,
        );
        showSwipeDismissibleMenu<String>(
          context: context,
          position: relativeRect,
          items: [
            PopupMenuItem(
              value: 'save',
              child: _BytesMenuRow(
                icon: Symbols.save_alt_rounded,
                label: ImageSaveUtils.actionLabel,
              ),
            ),
            PopupMenuItem(
              value: 'copy',
              child: _BytesMenuRow(
                icon: Symbols.content_copy_rounded,
                label: S.current.image_copyImage,
              ),
            ),
            // Linux 上 share_plus 不支持分享文件,隐藏该项
            if (ShareUtils.canShareFiles)
              PopupMenuItem(
                value: 'share',
                child: _BytesMenuRow(
                  icon: Symbols.share_rounded,
                  label: S.current.common_shareImage,
                ),
              ),
          ],
        ).then((value) {
          switch (value) {
            case 'save':
              _saveMemoryImage();
            case 'copy':
              _copyMemoryImage();
            case 'share':
              _shareMemoryImage();
          }
        });
        return;
      }
    }

    AppBottomSheet.show(
      context: context,
      contentPadding: EdgeInsets.zero,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.save_alt_rounded),
              title: Text(ImageSaveUtils.actionLabel),
              onTap: () {
                Navigator.pop(ctx);
                _saveMemoryImage();
              },
            ),
            ListTile(
              leading: const Icon(Symbols.content_copy_rounded),
              title: Text(S.current.image_copyImage),
              onTap: () {
                Navigator.pop(ctx);
                _copyMemoryImage();
              },
            ),
            if (ShareUtils.canShareFiles)
              ListTile(
                leading: const Icon(Symbols.share_rounded),
                title: Text(S.current.common_shareImage),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareMemoryImage();
                },
              ),
          ],
        );
      },
    );
  }

  /// 分享当前图片
  Future<void> _shareImage() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      final imageUrl = _currentImageUrl;
      // 获取缓存文件（如果不存在会自动下载）
      final file = await BlobImageCache.getFile(
        BlobImageCache.originalBucket,
        imageUrl,
      );

      // 复制为可读文件名的临时文件再分享（缓存文件按 md5 寻址）：
      // 原始文件名(接口/cooked) → URL 末段 → 时间戳,逐级回退。
      await ShareUtils.shareImageFile(
        file,
        ext: BlobImageCache.httpUrlExtension(imageUrl),
        fileName: _currentFilename,
        urlHint: imageUrl,
      );
    } catch (e) {
      debugPrint('Share image error: $e');
      if (mounted) {
        ToastService.showError(S.current.common_shareFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _isSharing = false);
      }
    }
  }

  /// 桌面端包裹快捷键退出（从 shortcutProvider 读取 closeOverlay 绑定）
  Widget _wrapDesktopShortcuts(BuildContext context, Widget child) {
    if (!PlatformUtils.isDesktop) return child;
    return Consumer(
      builder: (context, ref, _) {
        final binding = ref
            .read(shortcutProvider.notifier)
            .getBinding(ShortcutAction.closeOverlay);
        return CallbackShortcuts(
          bindings: {
            if (binding != null)
              binding.activator: () => Navigator.of(context).pop(),
          },
          child: Focus(autofocus: true, child: child),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 内存图片模式
    if (widget.imageBytes != null) {
      return _wrapDesktopShortcuts(
        context,
        AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
          ),
          child: ExtendedImageSlidePage(
            slideAxis: SlideAxis.both,
            slideType: SlideType.onlyImage,
            slideEndHandler: (offset, {required state, required details}) =>
                _slideShouldPop(
                  offset,
                  details,
                  state.pageSize,
                  SlideAxis.both,
                ),
            slidePageBackgroundHandler: (Offset offset, Size pageSize) {
              double progress = offset.distance / (pageSize.height);
              return Colors.black.withValues(
                alpha: (1.0 - progress).clamp(0.0, 1.0),
              );
            },
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  GestureDetector(
                    onTap: _toggleUI,
                    onLongPress: () => _showBytesContextMenu(context),
                    onSecondaryTapUp: (details) => _showBytesContextMenu(
                      context,
                      position: details.globalPosition,
                    ),
                    child: GestureImageView(
                      image: MemoryImage(widget.imageBytes!),
                      controller: _obtainGestureController(
                        0,
                        inPageView: false,
                        maxScale: 5.0,
                        animationMaxScale: 5.5,
                      ),
                      fit: BoxFit.contain,
                      enableSlideOutPage: true,
                      onDoubleTap: (state) {
                        _hideUI();
                        handleDoubleTapZoom(state);
                      },
                    ),
                  ),
                  IgnorePointer(
                    ignoring: !_showUI,
                    child: AnimatedOpacity(
                      opacity: _showUI ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Stack(
                        children: [
                          // Top Gradient for status bar visibility
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 100,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.6),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),

                          Positioned(
                            top: MediaQuery.of(context).padding.top + 10,
                            right: 20,
                            child: CircleAvatar(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.5,
                              ),
                              child: IconButton(
                                icon: const Icon(
                                  Symbols.close_rounded,
                                  color: Colors.white,
                                ),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ),
                          ),
                          Positioned(
                            top: MediaQuery.of(context).padding.top + 10,
                            left: 20,
                            child: CircleAvatar(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.5,
                              ),
                              child: _isSaving
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: LoadingSpinner(
                                        size: 20,
                                        color: Colors.white,
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(
                                        Symbols.save_alt_rounded,
                                        color: Colors.white,
                                      ),
                                      onPressed: _saveMemoryImage,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final images = widget.galleryImages ?? [widget.imageUrl!];
    final bool isGallery = images.length > 1;

    return _wrapDesktopShortcuts(
      context,
      AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: ExtendedImageSlidePage(
          slideAxis: SlideAxis.vertical, // 仅垂直滑动关闭，避免与左右切换图片冲突
          slideType: SlideType.onlyImage,
          slideEndHandler: (offset, {required state, required details}) =>
              _slideShouldPop(
                offset,
                details,
                state.pageSize,
                SlideAxis.vertical,
              ),
          // 只处理背景透明度，不干预关闭逻辑，让库自己处理 pop
          slidePageBackgroundHandler: (Offset offset, Size pageSize) {
            // 使用垂直偏移量计算背景透明度（与 slideAxis: vertical 匹配）
            double progress = offset.dy.abs() / (pageSize.height / 2);
            return Colors.black.withValues(
              alpha: (1.0 - progress).clamp(0.0, 1.0),
            );
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                if (!isGallery)
                  // 单图模式：使用最简结构，避免 PageView 带来的空白/手势问题
                  GestureDetector(
                    onTap: _toggleUI,
                    onLongPress: () => _showContextMenu(context),
                    onSecondaryTapUp: (details) => _showContextMenu(
                      context,
                      position: details.globalPosition,
                    ),
                    child: GestureImageView(
                      image: _clampedViewerProvider(widget.imageUrl!),
                      // 即使缩略图 URL 与原图 URL 相同也要传：两者分别走
                      // content/original bucket，且源页面已经把 content 版本
                      // 解码进缓存。旧代码按 URL 相等直接丢掉占位，弱网下只剩
                      // 空黑画布等待 original bucket 下载。
                      placeholder: widget.thumbnailUrl != null
                          ? _thumbnailProvider(widget.thumbnailUrl!)
                          : null,
                      controller: _obtainGestureController(
                        0,
                        inPageView: false,
                      ),
                      fit: BoxFit.contain,
                      enableSlideOutPage: true,
                      heroBuilder: widget.heroTag != null
                          ? (child) => _buildViewerHero(
                              tag: widget.heroTag!,
                              thumbUrl: widget.thumbnailUrl,
                              child: child,
                            )
                          : null,
                      onDoubleTap: (state) {
                        _hideUI();
                        handleDoubleTapZoom(state, imageUrl: widget.imageUrl);
                      },
                      onImageLoaded: (imageInfo) {
                        // 缓存图片尺寸用于智能缩放
                        cacheImageSize(
                          widget.imageUrl!,
                          Size(
                            imageInfo.image.width.toDouble(),
                            imageInfo.image.height.toDouble(),
                          ),
                        );
                      },
                      failedBuilder: (context, _) =>
                          _buildSvgFallback(widget.imageUrl!),
                      progressBuilder: _buildImageLoadingProgress,
                    ),
                  )
                else
                  // 画廊模式：使用 ExtendedImageGesturePageView 支持滑动切换
                  GestureDetector(
                    onTap: _toggleUI,
                    onLongPress: () => _showContextMenu(context),
                    onSecondaryTapUp: (details) => _showContextMenu(
                      context,
                      position: details.globalPosition,
                    ),
                    child: ExtendedImageGesturePageView.builder(
                      itemCount: images.length,
                      physics: const BouncingScrollPhysics(),
                      controller: _ensureGalleryPageController,
                      onPageChanged: (index) {
                        // 离场页重置缩放(与旧行为一致:PageView 不缓存
                        // 离屏页,离页即回初始状态)
                        _gestureControllers[currentIndex]?.reset();
                        setState(() {
                          currentIndex = index;
                        });
                        _activeHeroPage.value = index;
                        // 更新底层页面应该隐藏的图片
                        final newTag = _getHeroTagForIndex(index);
                        HeroVisibilityController.instance.setHiddenTag(newTag);
                        // 预滚:把源页对应缩略图滚进可视区(黑底全不透明,
                        // 底下滚动无感),保证之后任意 pop 路径 Hero 都能
                        // 飞回当前这张的原位
                        if (newTag != null) {
                          unawaited(
                            HeroVisibilityController.instance
                                .ensureSourceVisible(newTag),
                          );
                        }
                        // 预加载相邻图片
                        _preloadAdjacentImages();
                      },
                      itemBuilder: (context, index) {
                        final url = images[index];
                        final thumbUrl = _getThumbnailForIndex(index);

                        // 用 ValueListenableBuilder 监听页码变化
                        // 确保 PageView 缓存的页面在切换时也会重建，移除旧 Hero
                        return ValueListenableBuilder<int>(
                          valueListenable: _activeHeroPage,
                          builder: (context, activePage, _) {
                            String? heroTag;
                            if (index == activePage) {
                              if (widget.heroTags != null &&
                                  index < widget.heroTags!.length) {
                                heroTag = widget.heroTags![index];
                              } else if (index == widget.initialIndex &&
                                  widget.heroTag != null) {
                                heroTag = widget.heroTag;
                              }
                            }

                            return GestureImageView(
                              image: _clampedViewerProvider(url),
                              placeholder: thumbUrl != null
                                  ? _thumbnailProvider(thumbUrl)
                                  : null,
                              controller: _obtainGestureController(
                                index,
                                inPageView: true, // 必须为 true
                              ),
                              fit: BoxFit.contain,
                              enableSlideOutPage: true,
                              inPageView: true,
                              heroBuilder: heroTag != null
                                  ? (child) => _buildViewerHero(
                                      tag: heroTag!,
                                      thumbUrl: thumbUrl,
                                      child: child,
                                    )
                                  : null,
                              onDoubleTap: (state) {
                                _hideUI();
                                handleDoubleTapZoom(state, imageUrl: url);
                              },
                              onImageLoaded: (imageInfo) {
                                // 缓存图片尺寸用于智能缩放
                                cacheImageSize(
                                  url,
                                  Size(
                                    imageInfo.image.width.toDouble(),
                                    imageInfo.image.height.toDouble(),
                                  ),
                                );
                              },
                              failedBuilder: (context, _) =>
                                  _buildSvgFallback(url),
                              progressBuilder: _buildImageLoadingProgress,
                            );
                          },
                        );
                      },
                    ),
                  ),

                IgnorePointer(
                  ignoring: !_showUI,
                  child: AnimatedOpacity(
                    opacity: _showUI ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Stack(
                      children: [
                        // Top Gradient for status bar visibility
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: 100,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.6),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),

                        // 顶部指示器 (仅画廊模式)
                        if (isGallery)
                          Positioned(
                            top: MediaQuery.of(context).padding.top + 15,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  "${currentIndex + 1} / ${images.length}",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Close button
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 10,
                          right: 20,
                          child: CircleAvatar(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.5,
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Symbols.close_rounded,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ),
                        ),

                        // Save button
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 10,
                          left: 20,
                          child: CircleAvatar(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.5,
                            ),
                            child: _isSaving
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: LoadingSpinner(
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                  )
                                : IconButton(
                                    icon: const Icon(
                                      Symbols.save_alt_rounded,
                                      color: Colors.white,
                                    ),
                                    onPressed: _saveCurrentImage,
                                  ),
                          ),
                        ),

                        // Share button（Linux 上 share_plus 不支持分享文件）
                        if (widget.enableShare && ShareUtils.canShareFiles)
                          Positioned(
                            top: MediaQuery.of(context).padding.top + 10,
                            left: 70, // 保存按钮右侧 (20 + 40 + 10)
                            child: CircleAvatar(
                              backgroundColor: Colors.black.withValues(
                                alpha: 0.5,
                              ),
                              child: _isSharing
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: LoadingSpinner(
                                        size: 20,
                                        color: Colors.white,
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(
                                        Symbols.share_rounded,
                                        color: Colors.white,
                                      ),
                                      onPressed: _shareImage,
                                    ),
                            ),
                          ),

                        // 底部文件名栏
                        if (_currentFilename != null &&
                            _currentFilename!.isNotEmpty)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: EdgeInsets.only(
                                left: 16,
                                right: 16,
                                top: 12,
                                bottom:
                                    MediaQuery.of(context).padding.bottom + 12,
                              ),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.6),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                              child: Text(
                                _currentFilename!,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 原图下载进度：服务端给出 Content-Length 时显示确定进度，否则显示
  /// 不定态。M3eCircularProgress 内部读取全局 M3E 开关，开启时为波浪环，
  /// 关闭时自动回退经典 CircularProgressIndicator。
  Widget _buildImageLoadingProgress(
    BuildContext context,
    ImageChunkEvent? event,
  ) {
    final total = event?.expectedTotalBytes;
    final value = total != null && total > 0
        ? (event!.cumulativeBytesLoaded / total).clamp(0.0, 1.0)
        : null;
    return Center(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0x66000000),
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: M3eCircularProgress(
            value: value,
            size: 32,
            strokeWidth: 3,
            color: Colors.white,
            trackColor: Colors.white24,
          ),
        ),
      ),
    );
  }

  /// 获取指定索引的缩略图 URL。
  ///
  /// 初始页必须优先使用点击入口显式传入的 [ImageViewerPage.thumbnailUrl]：
  /// 它是源端当下真正显示的 srcset 档位 URL，且对应位图已在 ImageCache。
  /// [ImageViewerPage.thumbnailUrls] 来自全帖画廊汇总，可能仍是 cooked 的
  /// 默认 src，和当前源端按 DPR 选出的 srcset URL 不同；旧顺序在画廊模式
  /// 会覆盖掉正确 URL，导致查看器重新下载另一个“缩略图”，于是先黑很久，
  /// 下载完才显示缩略图。
  String? _getThumbnailForIndex(int index) =>
      ImageViewerPage.debugThumbnailUrlForIndex(
        index: index,
        initialIndex: widget.initialIndex,
        thumbnailUrl: widget.thumbnailUrl,
        thumbnailUrls: widget.thumbnailUrls,
      );

  /// 构建图片解码 fallback 组件（SVG / AVIF）
  Widget _buildSvgFallback(String imageUrl) {
    return _ImageDecodeFallback(imageUrl: imageUrl);
  }
}

/// 图片解码 fallback 组件
/// 当普通图片解码失败时，依次检测 SVG 和 AVIF 并渲染
class _ImageDecodeFallback extends StatefulWidget {
  final String imageUrl;

  const _ImageDecodeFallback({required this.imageUrl});

  @override
  State<_ImageDecodeFallback> createState() => _ImageDecodeFallbackState();
}

class _ImageDecodeFallbackState extends State<_ImageDecodeFallback> {
  ScalableImage? _svgSi;
  String? _animatedSvgSource;
  bool _checked = false;
  bool _isSvg = false;
  bool _isAvif = false;

  @override
  void initState() {
    super.initState();
    _detectAndDecode();
  }

  Future<void> _detectAndDecode() async {
    try {
      final bytes = await BlobImageCache.fetch(
        BlobImageCache.originalBucket,
        widget.imageUrl,
      );

      if (bytes.isEmpty || !mounted) return;

      // 1. 先检测 SVG
      if (_isSvgContent(bytes)) {
        final raw = SvgUtils.decodeSvgBytes(bytes);
        // 动画 SVG 走 full_svg_flutter;查看器是用户主动打开的单图,直接播
        if (AnimatedSvgView.hasAnimations(raw)) {
          if (mounted) {
            setState(() {
              _animatedSvgSource = raw;
              _isSvg = true;
              _checked = true;
            });
          }
          return;
        }
        final svgString = SvgUtils.sanitize(raw);
        final si = ScalableImage.fromSvgString(svgString, warnF: (_) {});
        if (mounted) {
          setState(() {
            _svgSi = si;
            _isSvg = true;
            _checked = true;
          });
        }
        return;
      }

      // 2. 检测 AVIF magic bytes，交给 AvifImageProvider 解码（支持动画）
      if (_isAvifContent(bytes)) {
        if (mounted) {
          setState(() {
            _isAvif = true;
            _checked = true;
          });
        }
        return;
      }

      if (mounted) {
        setState(() => _checked = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _checked = true);
      }
    }
  }

  bool _isSvgContent(List<int> bytes) {
    if (bytes.length < 5) return false;

    int start = 0;
    while (start < bytes.length &&
        (bytes[start] <= 32 ||
            bytes[start] == 0xEF ||
            bytes[start] == 0xBB ||
            bytes[start] == 0xBF)) {
      start++;
    }

    if (start >= bytes.length - 4) return false;

    final prefix = String.fromCharCodes(bytes.sublist(start, start + 5));
    return prefix.startsWith('<svg') || prefix.startsWith('<?xml');
  }

  /// 检测 AVIF magic bytes
  /// AVIF 文件: offset 4-7 为 "ftyp"，offset 8-11 为 "avif"/"avis"/"mif1"
  bool _isAvifContent(List<int> bytes) {
    if (bytes.length < 12) return false;

    // offset 4-7: "ftyp"
    final ftyp = String.fromCharCodes(bytes.sublist(4, 8));
    if (ftyp != 'ftyp') return false;

    // offset 8-11: brand
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    return brand == 'avif' || brand == 'avis' || brand == 'mif1';
  }

  @override
  Widget build(BuildContext context) {
    if (_isSvg && _animatedSvgSource != null) {
      return Center(
        child: AnimatedSvgView(
          svgSource: _animatedSvgSource!,
          alignment: Alignment.center,
          autoPlay: true,
        ),
      );
    }

    if (_isSvg && _svgSi != null) {
      return Center(
        child: ScalableImageWidget(si: _svgSi!, fit: BoxFit.contain),
      );
    }

    if (_isAvif) {
      // 使用 AvifImageProvider 解码并渲染，自动支持动画 AVIF
      return Center(
        child: Image(
          // 查看器要原图清晰度,放开帖内默认的 2048 帧上限;bucket 与
          // 本组件嗅探时的 fetch 一致(original),避免同图双份缓存。
          image: AvifImageProvider(
            widget.imageUrl,
            maxDimension: null,
            bucket: BlobImageCache.originalBucket,
          ),
          fit: BoxFit.contain,
        ),
      );
    }

    if (!_checked) {
      return const Center(child: LoadingSpinner());
    }

    // 不是 SVG 也不是 AVIF，显示错误图标
    return const Center(
      child: Icon(
        Symbols.broken_image_rounded,
        size: 64,
        color: Colors.white54,
      ),
    );
  }
}

class _BytesMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _BytesMenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}
