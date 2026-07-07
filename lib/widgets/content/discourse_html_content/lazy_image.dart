import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../common/anchor_guard_sliver.dart';
import '../../common/hero_image.dart';

/// 帖子正文内容图组件:固定占位尺寸 + 解码分辨率约束 + 重绘隔离 + Hero。
///
/// 懒加载边界由 sliver 虚拟化承担(item 进入 cacheExtent 才挂载,挂载即
/// 开始加载 = 提前一个 cacheExtent 预取,进视口时大概率已就绪)。此前在
/// 组件内再用 VisibilityDetector 拦一道反而把加载起点推迟到"已进视口",
/// 用户必然先看到占位/spinner;且每张图一个 VisibilityDetector 有全局
/// 可见性计算开销。
///
/// 性能关键点:
/// - **解码约束**:按显示宽 × dpr 解码([ResizeImage.resizeIfNeeded]),
///   而不是原图全分辨率 —— Discourse 原图动辄 2000-4000px,全尺寸解码
///   单张位图几十 MB,纹理上传卡 raster,且很快挤爆 imageCache 触发
///   驱逐-重解码循环(滚回来反复卡)。
/// - **RepaintBoundary**:加载 spinner / 动图逐帧 / 解码完成首绘的
///   markNeedsPaint 都隔离在图片自身区域,不再冒泡到帖子 segment 的
///   RepaintBoundary 造成整帖每帧重绘。
/// - **占位挂在 frameBuilder 而非 loadingBuilder**:loadingProgress 只在
///   provider 上报 ImageChunkEvent 时非 null —— 自解码 provider(AVIF /
///   native 动图)从不上报,普通网络图在首字节到达前也是 null,只靠
///   loadingBuilder 意味着这些阶段显示的是"还没有帧的空 RawImage" =
///   空白一块。frameBuilder 以"首帧是否到达"为准,覆盖所有 provider。
class LazyImage extends StatefulWidget {
  /// 解码高度上限(物理像素):防长截图类窄高图按宽度解出超高位图。
  /// 见 build 内注释。
  static const int _kMaxDecodeHeight = 4096;

  final ImageProvider imageProvider;
  final double? width;
  final double? height;
  final BoxFit fit;
  final String heroTag;
  final VoidCallback? onTap;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 右键回调（桌面端）
  final GestureTapUpCallback? onSecondaryTapUp;

  /// 缓存 key（保留参数兼容旧调用方,当前未使用）
  final String? cacheKey;

  const LazyImage({
    super.key,
    required this.imageProvider,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    required this.heroTag,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapUp,
    this.cacheKey,
  });

  @override
  State<LazyImage> createState() => _LazyImageState();
}

class _LazyImageState extends State<LazyImage> {
  /// 无声明尺寸图片的实测宽高比记忆(cacheKey/URL → w/h)。
  ///
  /// 这类图首次加载只能用 200px 高占位;若不记忆,图片滚出 cacheExtent
  /// 被回收、ImageCache 又驱逐了解码位图时,滚回来重建 = 再次 200 占位
  /// → SliverList 的记账(上次真实高度)对不上 → scrollOffsetCorrection
  /// 回跳(SCROLL-PROBE 抓到的负偏移区 backward jump 的图片份额)。
  /// 有记忆后重建首帧即以真实比例占位,重访零布局变化 —— 与
  /// DiscourseVideoPlayer 的比例记忆同款策略。
  static final Map<String, double> _knownAspectRatios = {};

  /// 本次会话解析到的实测比例(优先于静态记忆,驱动 AspectRatio)
  double? _resolvedRatio;

  ImageStream? _ratioStream;
  ImageStreamListener? _ratioListener;

  /// 无声明尺寸的图,首帧落地会把占位换成真实高度 —— 只武装一次哨兵
  bool _armedForFirstFrame = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveRatioIfNeeded();
  }

  @override
  void didUpdateWidget(LazyImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider) {
      _stopRatioResolve();
      _resolvedRatio = null;
      _resolveRatioIfNeeded();
    }
  }

  @override
  void dispose() {
    _stopRatioResolve();
    super.dispose();
  }

  bool get _hasFixedBox =>
      widget.width != null && widget.height != null && widget.height! > 0;

  /// 监听与 build 中同一 provider 的 ImageStream 拿实测尺寸(共享
  /// ImageCache 条目,不产生第二次解码),记入比例记忆。仅无声明尺寸
  /// 的图需要;拿到首帧即移除监听。
  void _resolveRatioIfNeeded() {
    if (_hasFixedBox || _ratioListener != null) return;

    final stream = _buildProvider(context).resolve(
      createLocalImageConfiguration(context),
    );
    void onImage(ImageInfo info, bool synchronousCall) {
      final ratio = info.image.height == 0
          ? null
          : info.image.width / info.image.height;
      info.dispose();
      if (ratio == null) return;
      final key = widget.cacheKey;
      if (key != null && key.isNotEmpty) {
        _knownAspectRatios[key] = ratio;
      }
      // 首帧已到,后续动图帧不再需要
      _stopRatioResolve();
      if (_resolvedRatio != null && (ratio - _resolvedRatio!).abs() < 0.01) {
        return;
      }
      if (synchronousCall) {
        // 缓存命中的同步回调发生在首次 build 前,直接赋值即可
        _resolvedRatio = ratio;
      } else if (mounted) {
        // 200 占位 → 真实比例的布局变化帧:武装哨兵,视口上方的图
        // 加载完成不把内容拉走
        if (!_armedForFirstFrame) {
          _armedForFirstFrame = true;
          AnchorGuardSliver.arm();
        }
        setState(() => _resolvedRatio = ratio);
      }
    }

    final listener = ImageStreamListener(onImage, onError: (_, _) {});
    _ratioStream = stream;
    _ratioListener = listener;
    stream.addListener(listener);
  }

  void _stopRatioResolve() {
    final listener = _ratioListener;
    if (listener != null) {
      _ratioStream?.removeListener(listener);
    }
    _ratioListener = null;
    _ratioStream = null;
  }

  /// 与 build 使用完全相同的 provider 参数,保证 ImageStream 同 key 共享
  ImageProvider _buildProvider(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logicalWidth = widget.width ?? MediaQuery.sizeOf(context).width;
    final cacheWidth = (logicalWidth * dpr).round().clamp(1, 1 << 16);
    return ResizeImage(
      widget.imageProvider,
      width: cacheWidth,
      height: LazyImage._kMaxDecodeHeight,
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = widget.width;
    final height = widget.height;

    // 声明了完整尺寸 → 外层 AspectRatio 恒定,加载完成不改布局
    final hasFixedBox = width != null && height != null && height > 0;

    // 解码目标宽 = 显示逻辑宽(调用方已按列宽 clamp) × dpr;无声明尺寸的
    // 图退化到屏宽。fit 策略 = contain(保持宽高比,只缩不放)。
    //
    // 高度必须同时 cap:只约束宽度时,长截图(宽高比 1:10 常见)按宽
    // 2000+ 解码 → 高 20000+ → 单张 100MB+ 纹理且超 GPU 纹理上限,
    // 上传瞬间 raster 冻结几百 ms(转场首绘大帧的元凶之一)。4096 是
    // 低端 GPU 的普遍安全上限;长图看细节走查看器的独立高清路径。
    // provider 构造统一走 _buildProvider。

    // 统一的占位框:frameBuilder(无进度事件的 provider / 首字节前)与
    // loadingBuilder(有进度事件)共用同一外观,避免阶段切换时闪变。
    // RepaintBoundary 包住 spinner:指示器每帧动画,不隔离的话脏区
    // 冒泡到外层图片级 RepaintBoundary,慢加载的大图占位(整图尺寸
    // 的层)会被每帧全量重栅格化 —— 实测就是"无动图页面 raster
    // 每帧 8ms 常驻、加载完自愈"的来源。
    Widget placeholderBox({double? progress}) {
      return Container(
        width: width,
        height: height ?? 200,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: RepaintBoundary(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress,
            ),
          ),
        ),
      );
    }

    final imageChild = Image(
      // 解码目标宽 = 显示逻辑宽 × dpr(见 _buildProvider);与比例监听
      // 使用同一 provider 参数,共享 ImageStream 与缓存条目
      image: _buildProvider(context),
      fit: widget.fit,
      width: width,
      height: height,
      // provider 变化(如窗口宽变化导致解码宽变)时保留旧帧,避免闪白
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame != null) return child;
        return placeholderBox();
      },
      loadingBuilder: (context, child, loadingProgress) {
        // 无进度事件(AVIF/native 动图全程、网络图首字节前)时,child 已由
        // frameBuilder 决定(占位或图),直接透传;有进度时显示进度值。
        if (loadingProgress == null) return child;
        if (loadingProgress.expectedTotalBytes == null) return child;
        return placeholderBox(
          progress: loadingProgress.cumulativeBytesLoaded /
              loadingProgress.expectedTotalBytes!,
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: width,
          height: height ?? 200,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.2,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Symbols.broken_image_rounded,
            color: theme.colorScheme.outline,
            size: 32,
          ),
        );
      },
    );

    // 使用 HeroImage 封装 Hero 动画及可见性控制
    Widget imageWidget = HeroImage(
      heroTag: widget.heroTag,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTapUp: widget.onSecondaryTapUp,
      child: imageChild,
    );

    // 重绘隔离:spinner/动图/首绘只重画图片区域,不连带整个帖子 segment
    imageWidget = RepaintBoundary(child: imageWidget);

    if (hasFixedBox) {
      return AspectRatio(
        aspectRatio: width / height,
        child: imageWidget,
      );
    }

    // 无声明尺寸:有实测/记忆比例就以其占位 —— 重访(回收后重建)首帧
    // 即终态高度,SliverList 记账一致,不再触发回滚时的 correction 回跳
    final knownRatio = _resolvedRatio ??
        ((widget.cacheKey != null && widget.cacheKey!.isNotEmpty)
            ? _knownAspectRatios[widget.cacheKey!]
            : null);
    if (knownRatio != null && knownRatio > 0) {
      return AspectRatio(aspectRatio: knownRatio, child: imageWidget);
    }

    return imageWidget;
  }
}
