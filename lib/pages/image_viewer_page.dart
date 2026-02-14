import 'package:flutter/material.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gal/gal.dart';
import '../services/discourse_cache_manager.dart';
import '../utils/double_tap_zoom_controller.dart';
import '../utils/hero_visibility_controller.dart';
import '../utils/svg_utils.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';
import '../widgets/common/loading_spinner.dart';

part 'image_viewer_page/_viewer_state.dart';

class ImageViewerPage extends StatefulWidget {
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
  }) : assert(imageUrl != null || imageBytes != null);

  /// 使用透明路由打开图片查看器
  static void open(
    BuildContext context,
    String imageUrl, {
    String? heroTag,
    List<String>? galleryImages,
    List<String>? heroTags,
    int initialIndex = 0,
    bool enableShare = false,
    String? thumbnailUrl,
    List<String>? thumbnailUrls,
  }) {
    Navigator.push(
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
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
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
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with TickerProviderStateMixin, DoubleTapZoomMixin {
  late int currentIndex;
  bool _isSaving = false;
  bool _isSharing = false;
  bool _showUI = true;
  final DiscourseCacheManager _cacheManager = DiscourseCacheManager();
  /// 通知所有缓存页面当前活跃的 Hero 页码变化，确保只有当前页有 Hero
  late final ValueNotifier<int> _activeHeroPage;

  /// 获取指定索引的 hero tag
  String? _getHeroTagForIndex(int index) {
    if (widget.heroTags != null && index < widget.heroTags!.length) {
      return widget.heroTags![index];
    } else if (index == widget.initialIndex && widget.heroTag != null) {
      return widget.heroTag;
    }
    return null;
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
    HeroVisibilityController.instance.setHiddenTagSilent(_getHeroTagForIndex(currentIndex));
  }

  @override
  void dispose() {
    HeroVisibilityController.instance.clear();
    _activeHeroPage.dispose();
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
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
    }
  }

  void _restoreSystemUI() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    _cacheManager.preloadImages(preloadUrls);
  }

  /// 获取当前显示的图片 URL
  String get _currentImageUrl {
    final images = widget.galleryImages ?? [widget.imageUrl!];
    return images[currentIndex];
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请授予相册访问权限')),
            );
          }
          return;
        }
      }

      // 使用缓存管理器获取图片字节（优先从缓存读取）
      final imageUrl = _currentImageUrl;
      final Uint8List? imageBytes = await _cacheManager.getImageBytes(imageUrl);

      if (imageBytes == null || imageBytes.isEmpty) {
        throw Exception('获取图片失败');
      }

      // 使用 putImageBytes 直接保存字节数据到相册
      final ext = _getExtensionFromUrl(imageUrl);
      await Gal.putImageBytes(imageBytes, name: 'fluxdo_${DateTime.now().millisecondsSinceEpoch}.$ext');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('图片已保存到相册'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on GalException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: ${e.type.message}')),
        );
      }
    } catch (e) {
      debugPrint('Save image error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存失败，请重试')),
        );
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
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请授予相册访问权限')));
        return;
      }
      await Gal.putImageBytes(widget.imageBytes!, name: 'fluxdo_${DateTime.now().millisecondsSinceEpoch}.png');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('图片已保存到相册'), behavior: SnackBarBehavior.floating));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
    } catch (e) {
      debugPrint('[ImageViewer] Failed to parse file extension: $e');
    }
    return 'jpg'; // 默认返回 jpg
  }

  /// 分享当前图片
  Future<void> _shareImage() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      final imageUrl = _currentImageUrl;
      // 获取缓存文件（如果不存在会自动下载）
      final file = await _cacheManager.getSingleFile(imageUrl);

      // 分享文件
      final xFile = XFile(file.path, mimeType: 'image/${_getExtensionFromUrl(imageUrl)}');
      await SharePlus.instance.share(ShareParams(files: [xFile], text: imageUrl));
    } catch (e) {
      debugPrint('Share image error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('分享失败，请重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSharing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 内存图片模式
    if (widget.imageBytes != null) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: ExtendedImageSlidePage(
          slideAxis: SlideAxis.both,
          slideType: SlideType.onlyImage,
          slidePageBackgroundHandler: (Offset offset, Size pageSize) {
            double progress = offset.distance / (pageSize.height);
            return Colors.black.withValues(alpha: (1.0 - progress).clamp(0.0, 1.0));
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                GestureDetector(
                  onTap: _toggleUI,
                  child: ExtendedImage.memory(
                    widget.imageBytes!,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.contain,
                    mode: ExtendedImageMode.gesture,
                    enableSlideOutPage: true,
                    initGestureConfigHandler: (state) => GestureConfig(
                      minScale: 0.9, animationMinScale: 0.7, maxScale: 5.0, animationMaxScale: 5.5,
                      speed: 1.0, inertialSpeed: 500.0, initialScale: 1.0, inPageView: false,
                    ),
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
                            backgroundColor: Colors.black.withValues(alpha: 0.5),
                            child: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.of(context).pop()),
                          ),
                        ),
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 10,
                          left: 20,
                          child: CircleAvatar(
                            backgroundColor: Colors.black.withValues(alpha: 0.5),
                            child: _isSaving
                                ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)))
                                : IconButton(icon: const Icon(Icons.save_alt, color: Colors.white), onPressed: _saveMemoryImage),
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
      );
    }

    final images = widget.galleryImages ?? [widget.imageUrl!];
    final bool isGallery = images.length > 1;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: ExtendedImageSlidePage(
      slideAxis: SlideAxis.vertical,  // 仅垂直滑动关闭，避免与左右切换图片冲突
      slideType: SlideType.onlyImage,
      // 只处理背景透明度，不干预关闭逻辑，让库自己处理 pop
      slidePageBackgroundHandler: (Offset offset, Size pageSize) {
        // 使用垂直偏移量计算背景透明度（与 slideAxis: vertical 匹配）
        double progress = offset.dy.abs() / (pageSize.height / 2);
        return Colors.black.withValues(alpha: (1.0 - progress).clamp(0.0, 1.0));
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            if (!isGallery)
              // 单图模式：使用最简结构，避免 PageView 带来的空白/手势问题
              GestureDetector(
                onTap: _toggleUI,
                child: ExtendedImage(
                  image: discourseImageProvider(widget.imageUrl!),
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.contain,
                  mode: ExtendedImageMode.gesture,
                  enableSlideOutPage: true,
                  heroBuilderForSlidingPage: widget.heroTag != null
                      ? (child) => Hero(tag: widget.heroTag!, child: child)
                      : null,
                  initGestureConfigHandler: (state) {
                    return GestureConfig(
                      minScale: 0.9,
                      animationMinScale: 0.7,
                      maxScale: 4.0,
                      animationMaxScale: 4.5,
                      speed: 1.0,
                      inertialSpeed: 500.0,
                      initialScale: 1.0,
                      inPageView: false,
                      initialAlignment: InitialAlignment.center,
                    );
                  },
                  onDoubleTap: (state) {
                    _hideUI();
                    handleDoubleTapZoom(state, imageUrl: widget.imageUrl);
                  },
                  loadStateChanged: (state) {
                    // 加载中时显示缩略图（如果有）
                    if (state.extendedImageLoadState == LoadState.loading) {
                      if (widget.thumbnailUrl != null && widget.thumbnailUrl != widget.imageUrl) {
                        return Image(
                          image: discourseImageProvider(widget.thumbnailUrl!),
                          fit: BoxFit.contain,
                        );
                      }
                    }
                    // 加载失败时检测是否为 SVG
                    if (state.extendedImageLoadState == LoadState.failed) {
                      return _buildSvgFallback(widget.imageUrl!);
                    }
                    // 缓存图片尺寸用于智能缩放
                    if (state.extendedImageLoadState == LoadState.completed) {
                      final imageInfo = state.extendedImageInfo;
                      if (imageInfo != null && widget.imageUrl != null) {
                        cacheImageSize(widget.imageUrl!, Size(
                          imageInfo.image.width.toDouble(),
                          imageInfo.image.height.toDouble(),
                        ));
                      }
                    }
                    return null;
                  },
                ),
              )
            else
              // 画廊模式：使用 ExtendedImageGesturePageView 支持滑动切换
              GestureDetector(
                onTap: _toggleUI,
                child: ExtendedImageGesturePageView.builder(
                  itemCount: images.length,
                  physics: const BouncingScrollPhysics(),
                  controller: ExtendedPageController(
                    initialPage: widget.initialIndex,
                    pageSpacing: 50,
                  ),
                  onPageChanged: (index) {
                    setState(() {
                      currentIndex = index;
                    });
                    _activeHeroPage.value = index;
                    // 更新底层页面应该隐藏的图片
                    HeroVisibilityController.instance.setHiddenTag(_getHeroTagForIndex(index));
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
                          if (widget.heroTags != null && index < widget.heroTags!.length) {
                            heroTag = widget.heroTags![index];
                          } else if (index == widget.initialIndex && widget.heroTag != null) {
                            heroTag = widget.heroTag;
                          }
                        }

                        return ExtendedImage(
                          image: discourseImageProvider(url),
                          mode: ExtendedImageMode.gesture,
                          enableSlideOutPage: true,
                          heroBuilderForSlidingPage: heroTag != null
                              ? (child) => Hero(tag: heroTag!, child: child)
                              : null,
                          initGestureConfigHandler: (state) {
                            return GestureConfig(
                              minScale: 0.9,
                              animationMinScale: 0.7,
                              maxScale: 4.0,
                              animationMaxScale: 4.5,
                              speed: 1.0,
                              inertialSpeed: 500.0,
                              initialScale: 1.0,
                              inPageView: true, // 必须为 true
                              initialAlignment: InitialAlignment.center,
                            );
                          },
                          onDoubleTap: (state) {
                            _hideUI();
                            handleDoubleTapZoom(state, imageUrl: url);
                          },
                          loadStateChanged: (state) {
                            // 加载中时显示缩略图（如果有）
                            if (state.extendedImageLoadState == LoadState.loading) {
                              if (thumbUrl != null && thumbUrl != url) {
                                return Image(
                                  image: discourseImageProvider(thumbUrl),
                                  fit: BoxFit.contain,
                                );
                              }
                              return const Center(child: LoadingSpinner());
                            }
                            // 加载失败时检测是否为 SVG
                            if (state.extendedImageLoadState == LoadState.failed) {
                              return _buildSvgFallback(url);
                            }
                            // 缓存图片尺寸用于智能缩放
                            if (state.extendedImageLoadState == LoadState.completed) {
                              final imageInfo = state.extendedImageInfo;
                              if (imageInfo != null) {
                                cacheImageSize(url, Size(
                                  imageInfo.image.width.toDouble(),
                                  imageInfo.image.height.toDouble(),
                                ));
                              }
                            }
                            return null;
                          },
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
                              Colors.black.withValues(alpha:0.6),
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
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              "${currentIndex + 1} / ${images.length}",
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          ),
                        ),
                      ),

                    // Close button
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 10,
                      right: 20,
                      child: CircleAvatar(
                        backgroundColor: Colors.black.withValues(alpha: 0.5),
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),

                    // Save button
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 10,
                      left: 20,
                      child: CircleAvatar(
                        backgroundColor: Colors.black.withValues(alpha: 0.5),
                        child: _isSaving
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.save_alt, color: Colors.white),
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
                          backgroundColor: Colors.black.withValues(alpha: 0.5),
                          child: _isSharing
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.share, color: Colors.white),
                                  onPressed: _shareImage,
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
    ));
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

  /// 构建 SVG fallback 组件
  Widget _buildSvgFallback(String imageUrl) {
    return _SvgImageFallback(
      imageUrl: imageUrl,
      cacheManager: _cacheManager,
    );
  }
}
