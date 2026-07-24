import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:gal/gal.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../services/discourse_cache_manager.dart';
import '../services/image_decode_spec_memo.dart';
import '../utils/double_tap_zoom_controller.dart';
import '../utils/hero_visibility_controller.dart';
import '../utils/screenshot_utils.dart';
import '../utils/svg_utils.dart';
import '../widgets/content/animated_svg_view.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../services/toast_service.dart';
import '../utils/platform_utils.dart';
import '../utils/share_utils.dart';
import '../widgets/common/app_bottom_sheet.dart';
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
  }) : assert(imageUrl != null || imageBytes != null);

  /// 查看器路由的黑底/整页淡入淡出曲线:与 Hero 飞行(吃路由原始
  /// animation,全程 300ms)异速 —— push 前 60%(~180ms)完成淡入、
  /// pop 前 60% 完成淡出(reverseCurve 的 t 轴仍是 parent 值,
  /// Interval(0.4,1.0) 即 parent 1→0.4 期间完成 1→0),背景先立住/
  /// 先退场,图片随后落位/飞回,分层感更自然。
  static Animation<double> _routeFadeAnimation(Animation<double> animation) {
    return CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      reverseCurve: const Interval(0.4, 1.0, curve: Curves.easeIn),
    );
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
  }) {
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
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: _routeFadeAnimation(animation),
            child: child,
          );
        },
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
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: _routeFadeAnimation(animation),
            child: child,
          );
        },
      ),
    );
  }

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with TickerProviderStateMixin, DoubleTapZoomMixin {
  late int currentIndex;
  bool _isSaving = false;
  bool _isSharing = false;
  bool _showUI = true;

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
  /// 源缩略图为 cover 裁剪展示(heroSourceFit == cover,目前只有网格
  /// 瓦片)时,飞行体升级为双层 crossfade:cover 纹理层(带圆角插值)
  /// 在飞行前段淡出、查看器 contain 层淡入 —— 消除起飞瞬间
  /// 「裁剪图→完整图」的跳变(落地/pop 方向反向同理)。
  ///
  /// 注意 pop 方向对网格也走本 shuttle(源端是朴素 Hero 无自定义
  /// shuttle,Flutter 回落到 fromHero=查看器侧)。
  Widget _buildViewerHero({
    required String tag,
    required String? thumbUrl,
    required Widget child,
  }) {
    final bool coverSource =
        widget.heroSourceFit == BoxFit.cover && thumbUrl != null;
    return Hero(
      tag: tag,
      flightShuttleBuilder: !coverSource
          ? (_, _, _, _, _) => child
          : (flightContext, animation, direction, fromContext, toContext) {
              // push:cover 层在前 40% 淡出;pop:cover 层在后 40% 淡入
              // (animation 在 pop 方向由 1 走向 0,同一 Interval 语义对称)
              final Animation<double> coverOpacity = animation.drive(
                Tween<double>(begin: 1.0, end: 0.0).chain(
                  CurveTween(
                    curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
                  ),
                ),
              );
              final double radius = widget.heroSourceRadius;
              return Stack(
                fit: StackFit.expand,
                children: [
                  child,
                  FadeTransition(
                    opacity: coverOpacity,
                    child: AnimatedBuilder(
                      animation: animation,
                      builder: (context, coverChild) => ClipRRect(
                        borderRadius: BorderRadius.circular(
                          radius * (1 - animation.value),
                        ),
                        child: coverChild,
                      ),
                      child: Image(
                        image: _thumbnailProvider(thumbUrl),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ],
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
    final longestPx =
        (view.physicalSize.longestSide * 3).clamp(2048.0, 8192.0).round();
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
  void dispose() {
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
      unawaited(
        BlobImageCache.precache(BlobImageCache.originalBucket, url),
      );
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

  /// 保存当前图片到相册
  Future<void> _saveCurrentImage() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      // 检查权限
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) {
            ToastService.showInfo(S.current.imageViewer_grantPermission);
          }
          return;
        }
      }

      // 使用缓存管理器获取图片字节（优先从缓存读取）
      final imageUrl = _currentImageUrl;
      final Uint8List imageBytes = await BlobImageCache.fetch(
        BlobImageCache.originalBucket,
        imageUrl,
      );

      if (imageBytes.isEmpty) {
        throw Exception(S.current.image_fetchFailed);
      }

      // 使用 putImageBytes 直接保存字节数据到相册
      final ext = _getExtensionFromUrl(imageUrl);
      await Gal.putImageBytes(
        imageBytes,
        name: 'fluxdo_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );

      if (mounted) {
        ToastService.showSuccess(S.current.imageViewer_imageSaved);
      }
    } on GalException catch (e) {
      if (mounted) {
        ToastService.showError(
          S.current.imageViewer_saveFailed(e.type.message),
        );
      }
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

  /// 保存内存图片到相册
  Future<void> _saveMemoryImage() async {
    if (_isSaving || widget.imageBytes == null) return;
    setState(() => _isSaving = true);
    try {
      final hasAccess = await Gal.hasAccess() || await Gal.requestAccess();
      if (!hasAccess) {
        if (mounted) {
          ToastService.showInfo(S.current.imageViewer_grantPermission);
        }
        return;
      }
      await Gal.putImageBytes(
        widget.imageBytes!,
        name: 'fluxdo_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      if (mounted) ToastService.showSuccess(S.current.imageViewer_imageSaved);
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.imageViewer_saveFailedRetry);
      }
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
                label: S.current.share_saveToGallery,
              ),
            ),
            PopupMenuItem(
              value: 'copy',
              child: _BytesMenuRow(
                icon: Symbols.content_copy_rounded,
                label: S.current.image_copyImage,
              ),
            ),
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
              title: Text(S.current.share_saveToGallery),
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

  /// 从 URL 中获取文件扩展名
  String _getExtensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final lastDot = path.lastIndexOf('.');
      if (lastDot != -1 && lastDot < path.length - 1) {
        return path.substring(lastDot + 1).toLowerCase();
      }
    } catch (_) {}
    return 'jpg'; // 默认返回 jpg
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

      // 分享文件
      final xFile = XFile(
        file.path,
        mimeType: 'image/${_getExtensionFromUrl(imageUrl)}',
      );
      await ShareUtils.shareOrSaveFile(xFile);
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
                _slideShouldPop(offset, details, state.pageSize,
                    SlideAxis.both),
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
              _slideShouldPop(offset, details, state.pageSize,
                  SlideAxis.vertical),
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
                      placeholder:
                          (widget.thumbnailUrl != null &&
                              widget.thumbnailUrl != widget.imageUrl)
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
                              placeholder: (thumbUrl != null && thumbUrl != url)
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
                              loadingBuilder: (context) =>
                                  const Center(child: LoadingSpinner()),
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

                        // Share button
                        if (widget.enableShare)
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

  /// 获取指定索引的缩略图 URL
  String? _getThumbnailForIndex(int index) {
    if (widget.thumbnailUrls != null && index < widget.thumbnailUrls!.length) {
      return widget.thumbnailUrls![index];
    } else if (index == widget.initialIndex && widget.thumbnailUrl != null) {
      return widget.thumbnailUrl;
    }
    return null;
  }

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
      child: Icon(Symbols.broken_image_rounded, size: 64, color: Colors.white54),
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
