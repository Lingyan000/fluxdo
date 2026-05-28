import 'dart:async';

import 'package:extended_image_library/extended_image_library.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Image;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';

import 'gesture/gesture.dart';
import 'gesture/slide_page.dart';
import 'gesture/slide_page_handler.dart';
import 'image/raw_image.dart';
import 'typedef.dart';
import 'utils.dart';

/// extended image lite - simplified version without editor support
class ExtendedImage extends StatefulWidget {
  ExtendedImage({
    super.key,
    required this.image,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.low,
    this.loadStateChanged,
    this.border,
    this.shape,
    this.borderRadius,
    this.clipBehavior = Clip.antiAlias,
    this.enableLoadState = false,
    this.beforePaintImage,
    this.afterPaintImage,
    this.mode = ExtendedImageMode.none,
    this.clearMemoryCacheIfFailed = true,
    this.onDoubleTap,
    this.initGestureConfigHandler,
    this.enableSlideOutPage = false,
    BoxConstraints? constraints,
    this.heroBuilderForSlidingPage,
    this.clearMemoryCacheWhenDispose = false,
    this.extendedImageGestureKey,
    this.isAntiAlias = false,
    this.handleLoadingProgress = false,
    this.layoutInsets = EdgeInsets.zero,
  }) : assert(constraints == null || constraints.debugAssertIsValid()),
       constraints =
           (width != null || height != null)
               ? constraints?.tighten(width: width, height: height) ??
                   BoxConstraints.tightFor(width: width, height: height)
               : constraints;

  ExtendedImage.asset(
    String name, {
    super.key,
    AssetBundle? bundle,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    double? scale,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    String? package,
    this.filterQuality = FilterQuality.low,
    this.loadStateChanged,
    this.shape,
    this.border,
    this.borderRadius,
    this.clipBehavior = Clip.antiAlias,
    this.enableLoadState = false,
    this.beforePaintImage,
    this.afterPaintImage,
    this.mode = ExtendedImageMode.none,
    this.clearMemoryCacheIfFailed = true,
    this.onDoubleTap,
    this.initGestureConfigHandler,
    this.enableSlideOutPage = false,
    BoxConstraints? constraints,
    this.heroBuilderForSlidingPage,
    this.clearMemoryCacheWhenDispose = false,
    this.extendedImageGestureKey,
    int? cacheWidth,
    int? cacheHeight,
    this.isAntiAlias = false,
    double? compressionRatio,
    int? maxBytes,
    bool cacheRawData = false,
    String? imageCacheName,
    this.layoutInsets = EdgeInsets.zero,
  }) : assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0),
       image = ExtendedResizeImage.resizeIfNeeded(
         provider:
             scale != null
                 ? ExtendedExactAssetImageProvider(
                   name,
                   bundle: bundle,
                   scale: scale,
                   package: package,
                   cacheRawData: cacheRawData,
                   imageCacheName: imageCacheName,
                 )
                 : ExtendedAssetImageProvider(
                   name,
                   bundle: bundle,
                   package: package,
                   cacheRawData: cacheRawData,
                   imageCacheName: imageCacheName,
                 ),
         compressionRatio: compressionRatio,
         maxBytes: maxBytes,
         cacheWidth: cacheWidth,
         cacheHeight: cacheHeight,
         cacheRawData: cacheRawData,
         imageCacheName: imageCacheName,
       ),
       constraints =
           (width != null || height != null)
               ? constraints?.tighten(width: width, height: height) ??
                   BoxConstraints.tightFor(width: width, height: height)
               : constraints,
       handleLoadingProgress = false;

  ExtendedImage.file(
    File file, {
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.low,
    this.loadStateChanged,
    this.shape,
    this.border,
    this.borderRadius,
    this.clipBehavior = Clip.antiAlias,
    this.enableLoadState = false,
    this.beforePaintImage,
    this.afterPaintImage,
    this.mode = ExtendedImageMode.none,
    this.clearMemoryCacheIfFailed = true,
    this.onDoubleTap,
    this.initGestureConfigHandler,
    this.enableSlideOutPage = false,
    BoxConstraints? constraints,
    this.heroBuilderForSlidingPage,
    this.clearMemoryCacheWhenDispose = false,
    this.extendedImageGestureKey,
    int? cacheWidth,
    int? cacheHeight,
    this.isAntiAlias = false,
    double? compressionRatio,
    int? maxBytes,
    bool cacheRawData = false,
    String? imageCacheName,
    this.layoutInsets = EdgeInsets.zero,
  }) : assert(
         !kIsWeb,
         'ExtendedImage.file is not supported on Flutter Web.',
       ),
       assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0),
       image = ExtendedResizeImage.resizeIfNeeded(
         provider: ExtendedFileImageProvider(
           file,
           scale: scale,
           cacheRawData: cacheRawData,
           imageCacheName: imageCacheName,
         ),
         compressionRatio: compressionRatio,
         maxBytes: maxBytes,
         cacheWidth: cacheWidth,
         cacheHeight: cacheHeight,
         cacheRawData: cacheRawData,
         imageCacheName: imageCacheName,
       ),
       constraints =
           (width != null || height != null)
               ? constraints?.tighten(width: width, height: height) ??
                   BoxConstraints.tightFor(width: width, height: height)
               : constraints,
       handleLoadingProgress = false;

  ExtendedImage.memory(
    Uint8List bytes, {
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.low,
    this.loadStateChanged,
    this.shape,
    this.border,
    this.borderRadius,
    this.clipBehavior = Clip.antiAlias,
    this.enableLoadState = false,
    this.beforePaintImage,
    this.afterPaintImage,
    this.mode = ExtendedImageMode.none,
    this.clearMemoryCacheIfFailed = true,
    this.onDoubleTap,
    this.initGestureConfigHandler,
    this.enableSlideOutPage = false,
    BoxConstraints? constraints,
    this.heroBuilderForSlidingPage,
    this.clearMemoryCacheWhenDispose = false,
    this.extendedImageGestureKey,
    int? cacheWidth,
    int? cacheHeight,
    this.isAntiAlias = false,
    double? compressionRatio,
    int? maxBytes,
    bool cacheRawData = false,
    String? imageCacheName,
    this.layoutInsets = EdgeInsets.zero,
  }) : assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0),
       image = ExtendedResizeImage.resizeIfNeeded(
         provider: ExtendedMemoryImageProvider(
           bytes,
           scale: scale,
           cacheRawData: cacheRawData,
           imageCacheName: imageCacheName,
         ),
         compressionRatio: compressionRatio,
         maxBytes: maxBytes,
         cacheWidth: cacheWidth,
         cacheHeight: cacheHeight,
         cacheRawData: cacheRawData,
         imageCacheName: imageCacheName,
       ),
       constraints =
           (width != null || height != null)
               ? constraints?.tighten(width: width, height: height) ??
                   BoxConstraints.tightFor(width: width, height: height)
               : constraints,
       handleLoadingProgress = false;

  ExtendedImage.network(
    String url, {
    super.key,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.low,
    this.loadStateChanged,
    this.shape,
    this.border,
    this.borderRadius,
    this.clipBehavior = Clip.antiAlias,
    this.enableLoadState = true,
    this.beforePaintImage,
    this.afterPaintImage,
    this.mode = ExtendedImageMode.none,
    this.clearMemoryCacheIfFailed = true,
    this.onDoubleTap,
    this.initGestureConfigHandler,
    this.enableSlideOutPage = false,
    BoxConstraints? constraints,
    CancellationToken? cancelToken,
    int retries = 3,
    Duration? timeLimit,
    Map<String, String>? headers,
    bool cache = true,
    double scale = 1.0,
    Duration timeRetry = const Duration(milliseconds: 100),
    this.heroBuilderForSlidingPage,
    this.clearMemoryCacheWhenDispose = false,
    this.handleLoadingProgress = false,
    this.extendedImageGestureKey,
    int? cacheWidth,
    int? cacheHeight,
    this.isAntiAlias = false,
    String? cacheKey,
    bool printError = true,
    double? compressionRatio,
    int? maxBytes,
    bool cacheRawData = false,
    String? imageCacheName,
    Duration? cacheMaxAge,
    this.layoutInsets = EdgeInsets.zero,
    WebHtmlElementStrategy webHtmlElementStrategy =
        WebHtmlElementStrategy.never,
  }) : assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0),
       image = ExtendedResizeImage.resizeIfNeeded(
         provider: ExtendedNetworkImageProvider(
           url,
           scale: scale,
           headers: headers,
           cache: cache,
           cancelToken: cancelToken,
           retries: retries,
           timeRetry: timeRetry,
           timeLimit: timeLimit,
           cacheKey: cacheKey,
           printError: printError,
           cacheRawData: cacheRawData,
           imageCacheName: imageCacheName,
           cacheMaxAge: cacheMaxAge,
           webHtmlElementStrategy: webHtmlElementStrategy,
         ),
         compressionRatio: compressionRatio,
         maxBytes: maxBytes,
         cacheWidth: cacheWidth,
         cacheHeight: cacheHeight,
         cacheRawData: cacheRawData,
         imageCacheName: imageCacheName,
       ),
       assert(constraints == null || constraints.debugAssertIsValid()),
       constraints =
           (width != null || height != null)
               ? constraints?.tighten(width: width, height: height) ??
                   BoxConstraints.tightFor(width: width, height: height)
               : constraints;

  final Key? extendedImageGestureKey;
  final bool handleLoadingProgress;
  final bool clearMemoryCacheWhenDispose;
  final HeroBuilderForSlidingPage? heroBuilderForSlidingPage;
  final bool enableSlideOutPage;
  final InitGestureConfigHandler? initGestureConfigHandler;
  final DoubleTap? onDoubleTap;
  final bool clearMemoryCacheIfFailed;
  final ExtendedImageMode mode;
  final BeforePaintImage? beforePaintImage;
  final AfterPaintImage? afterPaintImage;
  final bool enableLoadState;
  final Clip clipBehavior;
  final BoxShape? shape;
  final BoxBorder? border;
  final BorderRadius? borderRadius;
  final LoadStateChanged? loadStateChanged;
  final ImageProvider image;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;
  final Color? color;
  final Animation<double>? opacity;
  final FilterQuality filterQuality;
  final BlendMode? colorBlendMode;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageRepeat repeat;
  final Rect? centerSlice;
  final bool matchTextDirection;
  final bool gaplessPlayback;
  final String? semanticLabel;
  final bool excludeFromSemantics;
  final bool isAntiAlias;
  final EdgeInsets layoutInsets;

  @override
  State<ExtendedImage> createState() => _ExtendedImageState();

  static Widget Function(BuildContext context, ExtendedImageState state)
  globalStateWidgetBuilder = (BuildContext context, ExtendedImageState state) {
    switch (state.extendedImageLoadState) {
      case LoadState.loading:
        return Container(
          alignment: Alignment.center,
          child:
              Theme.of(context).platform == TargetPlatform.iOS
                  ? const CupertinoActivityIndicator(
                    animating: true,
                    radius: 16.0,
                  )
                  : CircularProgressIndicator(
                    strokeWidth: 2.0,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).primaryColor,
                    ),
                  ),
        );

      case LoadState.completed:
        return state.completedWidget;
      case LoadState.failed:
        return Container(
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {
              state.reLoadImage();
            },
            child: const Text('Failed to load image'),
          ),
        );
    }
  };
}

class _ExtendedImageState extends State<ExtendedImage>
    with ExtendedImageState, WidgetsBindingObserver {
  late LoadState _loadState;
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  bool _isListeningToStream = false;
  late bool _invertColors;
  ExtendedImageSlidePageState? _slidePageState;
  ImageChunkEvent? _loadingProgress;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ExtendedImage>> _scrollAwareContext;
  Object? _lastException;
  StackTrace? _lastStack;
  ImageStreamCompleterHandle? _completerHandle;

  ImageStreamListener? _imageStreamListener;

  @override
  Widget get completedWidget => _getCompletedWidget();

  @override
  ImageInfo? get extendedImageInfo => _imageInfo;

  @override
  LoadState get extendedImageLoadState => _loadState;

  @override
  int? get frameNumber => _frameNumber;

  @override
  ImageProvider get imageProvider => widget.image;

  @override
  Object? get imageStreamKey => _imageStream?.key;

  @override
  ExtendedImage get imageWidget => widget;

  @override
  bool get invertColors => _invertColors;

  @override
  Object? get lastException => _lastException;

  @override
  StackTrace? get lastStack => _lastStack;

  @override
  ImageChunkEvent? get loadingProgress => _loadingProgress;

  @override
  ExtendedImageSlidePageState? get slidePageState => _slidePageState;

  @override
  bool get wasSynchronouslyLoaded => _wasSynchronouslyLoaded;

  @override
  Widget build(BuildContext context) {
    Widget? current;

    returnLoadStateChangedWidget = false;
    if (widget.loadStateChanged != null) {
      current = widget.loadStateChanged?.call(this);
      if (current != null && returnLoadStateChangedWidget) {
        return current;
      }
    }

    if (current == null) {
      if (widget.enableLoadState) {
        current = ExtendedImage.globalStateWidgetBuilder(context, this);
      } else {
        if (_loadState == LoadState.completed) {
          current = _getCompletedWidget();
        } else {
          current = _buildExtendedRawImage();
        }
      }
    }

    if (widget.shape != null) {
      switch (widget.shape!) {
        case BoxShape.circle:
          current = ClipOval(clipBehavior: widget.clipBehavior, child: current);
          break;
        case BoxShape.rectangle:
          if (widget.borderRadius != null) {
            current = ClipRRect(
              borderRadius: widget.borderRadius!,
              clipBehavior: widget.clipBehavior,
              child: current,
            );
          }
          break;
      }
    }

    if (widget.border != null) {
      current = Container(
        decoration: BoxDecoration(
          border: widget.border,
          borderRadius: widget.borderRadius,
          shape: widget.shape ?? BoxShape.rectangle,
        ),
        child: current,
      );
    }

    if (widget.constraints != null) {
      current = ConstrainedBox(
        constraints: widget.constraints!,
        child: current,
      );
    }

    if (_slidePageState != null &&
        !(_loadState == LoadState.completed &&
            widget.mode == ExtendedImageMode.gesture)) {
      current = ExtendedImageSlidePageHandler(
        extendedImageSlidePageState: _slidePageState,
        heroBuilderForSlidingPage: widget.heroBuilderForSlidingPage,
        child: current,
      );
    }

    if (widget.excludeFromSemantics) {
      return current;
    }
    return Semantics(
      container: widget.semanticLabel != null,
      image: true,
      label: widget.semanticLabel ?? '',
      child: current,
    );
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    _slidePageState = null;
    if (widget.enableSlideOutPage) {
      _slidePageState =
          context.findAncestorStateOfType<ExtendedImageSlidePageState>();
    }

    if (TickerMode.valuesOf(context).enabled) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ExtendedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isListeningToStream &&
        widget.handleLoadingProgress != oldWidget.handleLoadingProgress) {
      final ImageStreamListener oldListener = _getListener();
      _imageStream!.addListener(_getListener(recreateListener: true));
      _imageStream!.removeListener(oldListener);
    }
    if (widget.image != oldWidget.image) {
      _resolveImage();
    }
    if (widget.enableSlideOutPage != oldWidget.enableSlideOutPage) {
      _slidePageState = null;
      if (widget.enableSlideOutPage) {
        _slidePageState =
            context.findAncestorStateOfType<ExtendedImageSlidePageState>();
      }
    }
  }

  @override
  void dispose() {
    assert(_imageStream != null);

    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replaceImage(info: null);

    if (widget.clearMemoryCacheWhenDispose) {
      widget.image
          .obtainCacheStatus(configuration: ImageConfiguration.empty)
          .then((ImageCacheStatus? value) {
            if (value?.keepAlive ?? false) {
              widget.image.evict();
            }
          });
    }

    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    returnLoadStateChangedWidget = false;
    _loadState = LoadState.loading;

    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ExtendedImage>>(this);
  }

  @override
  void reassemble() {
    _resolveImage();
    super.reassemble();
  }

  @override
  void reLoadImage() {
    _resolveImage(true);
  }

  Widget _buildExtendedRawImage() {
    return ExtendedRawImage(
      image: _imageInfo?.image,
      debugImageLabel: _imageInfo?.debugLabel,
      width: widget.width,
      height: widget.height,
      scale: _imageInfo?.scale ?? 1.0,
      color: widget.color,
      opacity: widget.opacity,
      colorBlendMode: widget.colorBlendMode,
      fit: widget.fit,
      alignment: widget.alignment,
      repeat: widget.repeat,
      centerSlice: widget.centerSlice,
      matchTextDirection: widget.matchTextDirection,
      invertColors: _invertColors,
      isAntiAlias: widget.isAntiAlias,
      filterQuality: widget.filterQuality,
      beforePaintImage: widget.beforePaintImage,
      afterPaintImage: widget.afterPaintImage,
      layoutInsets: widget.layoutInsets,
    );
  }

  Widget _getCompletedWidget() {
    Widget current;
    if (widget.mode == ExtendedImageMode.gesture) {
      current = ExtendedImageGesture(this, key: widget.extendedImageGestureKey);
    } else {
      current = _buildExtendedRawImage();
    }
    return current;
  }

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _lastStack = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: widget.handleLoadingProgress ? _handleImageChunk : null,
        onError: _loadFailed,
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageChunk(ImageChunkEvent event) {
    assert(widget.handleLoadingProgress);
    setState(() {
      _loadingProgress = event;
      _lastException = null;
      _lastStack = null;
    });
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    setState(() {
      _replaceImage(info: imageInfo);
      _loadState = LoadState.completed;
      _loadingProgress = null;
      _lastException = null;
      _lastStack = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }
    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;
    _isListeningToStream = true;
  }

  void _loadFailed(dynamic exception, StackTrace? stackTrace) {
    setState(() {
      _lastStack = stackTrace;
      _lastException = exception;
      _loadState = LoadState.failed;
    });

    if (widget.clearMemoryCacheIfFailed) {
      scheduleMicrotask(() {
        widget.image.evict();
      });
    }
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => oldImageInfo?.dispose(),
    );
    _imageInfo = info;
  }

  void _resolveImage([bool rebuild = false]) {
    if (rebuild) {
      widget.image.evict();
    }

    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );

    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size:
            widget.width != null && widget.height != null
                ? Size(widget.width!, widget.height!)
                : null,
      ),
    );

    if (_imageInfo != null && !rebuild && _imageStream?.key == newStream.key) {
      setState(() {
        _loadState = LoadState.completed;
      });
    }

    _updateSourceStream(newStream, rebuild: rebuild);
  }

  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) {
      return;
    }
    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }
    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  void _updateInvertColors() {
    _invertColors =
        MediaQuery.maybeOf(context)?.invertColors ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _updateSourceStream(ImageStream newStream, {bool rebuild = false}) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream?.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback || rebuild) {
      setState(() {
        _replaceImage(info: null);
        _loadState = LoadState.loading;
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }
}
