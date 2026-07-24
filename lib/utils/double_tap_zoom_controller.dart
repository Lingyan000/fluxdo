import 'package:flutter/material.dart';
import 'package:extended_image_lite/extended_image_lite.dart';

/// 双击缩放控制器
/// 
/// 实现微信/iOS Photos 风格的智能双击放大算法：
/// - 智能计算目标缩放比例（根据图片尺寸和屏幕尺寸）
/// - 以双击位置为中心进行缩放
/// - 使用 AnimationController + Tween 实现平滑的缩放动画
/// 
/// ## 使用方式
/// 
/// 在 State 中混入 `DoubleTapZoomMixin`：
/// ```dart
/// class _MyPageState extends State<MyPage> 
///     with TickerProviderStateMixin, DoubleTapZoomMixin {
///   
///   @override
///   void initState() {
///     super.initState();
///     initDoubleTapZoom();
///   }
///   
///   @override
///   void dispose() {
///     disposeDoubleTapZoom();
///     super.dispose();
///   }
///   
///   // 在 ExtendedImage 中使用
///   ExtendedImage(
///     onDoubleTap: (state) => handleDoubleTapZoom(state),
///   )
/// }
/// ```
class DoubleTapZoomController {
  /// 缩放阈值：当前缩放与 1.0 差值小于此值时认为是原始大小
  static const double scaleThreshold = 0.1;
  
  /// 默认放大倍数（当没有提供图片尺寸时使用）
  static const double defaultZoomScale = 2.0;
  
  /// 计算智能目标缩放比例
  /// 
  /// ## 算法逻辑
  /// 
  /// ### 步骤 1：判断当前状态
  /// - 如果当前已放大（scale > 1.0 + threshold） → 还原到 1.0
  /// - 如果当前是原始大小 → 计算智能放大比例
  /// 
  /// ### 步骤 2：智能放大比例计算
  /// 如果提供了 screenSize 和 imageSize：
  /// - 竖图（高 > 宽 * 1.25）：放大到填满屏幕宽度
  /// - 横图（宽 > 高 * 1.25）：放大到填满屏幕高度
  /// - 接近方形：放大到填满屏幕（取较大比例）
  /// 
  /// 如果只提供了 screenSize（没有 imageSize）：
  /// - 使用默认 2x 放大
  static double calculateTargetScale({
    required double currentScale,
    Size? screenSize,
    Size? imageSize,
    double maxZoomScale = 4.0,
  }) {
    // 如果当前已放大，双击还原
    if ((currentScale - 1.0).abs() > scaleThreshold) {
      return 1.0;
    }
    
    // 如果没有尺寸信息，使用默认 2x 放大
    if (screenSize == null || imageSize == null) {
      return defaultZoomScale.clamp(1.5, maxZoomScale);
    }
    
    return _calculateSmartScale(
      screenSize: screenSize,
      imageSize: imageSize,
      maxZoomScale: maxZoomScale,
    );
  }
  
  /// 计算智能缩放比例（内部方法）
  static double _calculateSmartScale({
    required Size screenSize,
    required Size imageSize,
    required double maxZoomScale,
  }) {
    final imageWidth = imageSize.width;
    final imageHeight = imageSize.height;
    
    if (imageWidth <= 0 || imageHeight <= 0) {
      return defaultZoomScale;
    }
    
    // 计算图片宽高比
    final imageAspectRatio = imageWidth / imageHeight;
    final screenAspectRatio = screenSize.width / screenSize.height;
    
    // 计算图片在 BoxFit.contain 模式下的显示尺寸
    double displayedWidth, displayedHeight;
    if (imageAspectRatio > screenAspectRatio) {
      // 图片比屏幕更宽（横图），以宽度为准
      displayedWidth = screenSize.width;
      displayedHeight = screenSize.width / imageAspectRatio;
    } else {
      // 图片比屏幕更高（竖图），以高度为准
      displayedHeight = screenSize.height;
      displayedWidth = screenSize.height * imageAspectRatio;
    }
    
    // 计算填满屏幕所需的缩放比例
    final scaleToFitWidth = screenSize.width / displayedWidth;
    final scaleToFitHeight = screenSize.height / displayedHeight;
    
    double targetScale;
    
    if (imageAspectRatio < 0.8) {
      // 明显的竖图：放大到填满屏幕宽度，方便上下滚动查看
      targetScale = scaleToFitWidth;
    } else if (imageAspectRatio > 1.25) {
      // 明显的横图：放大到填满屏幕高度，方便左右滚动查看
      targetScale = scaleToFitHeight;
    } else {
      // 接近方形的图片：使用较大的缩放比例（填满屏幕）
      targetScale = scaleToFitWidth > scaleToFitHeight 
          ? scaleToFitWidth 
          : scaleToFitHeight;
    }
    
    // 确保最小放大效果明显（至少 1.5 倍）
    if (targetScale < 1.5) {
      targetScale = defaultZoomScale;
    }
    
    return targetScale.clamp(1.5, maxZoomScale);
  }
  
  /// 判断当前是否已放大
  static bool isZoomedIn(double currentScale) {
    return (currentScale - 1.0).abs() > scaleThreshold;
  }
}

/// 双击缩放 Mixin
///
/// 算目标倍率后委托手势层的弹簧动画(动画由手势层持有,与其他动画
/// 同受指针打断管理);本 mixin 只保留图片尺寸缓存与目标倍率计算。
mixin DoubleTapZoomMixin<T extends StatefulWidget> on State<T>, TickerProviderStateMixin<T> {
  /// 缓存的图片尺寸（按 URL 存储）
  final Map<String, Size> _imageSizeCache = {};

  /// 初始化双击缩放
  void initDoubleTapZoom() {}

  /// 释放资源
  void disposeDoubleTapZoom() {}

  /// 缓存图片尺寸
  void cacheImageSize(String url, Size size) {
    _imageSizeCache[url] = size;
  }

  /// 获取缓存的图片尺寸
  Size? getCachedImageSize(String url) {
    return _imageSizeCache[url];
  }

  /// 处理双击事件:弹簧动画驱动缩放收敛(快起慢收,可无缝打断)。
  ///
  /// [state] 为包内 DoubleTapTarget 接口(由 GestureSurfaceState 实现)。
  void handleDoubleTapZoom(DoubleTapTarget state, {String? imageUrl}) {
    final pointerDownPosition = state.pointerDownPosition;
    if (pointerDownPosition == null) return;

    final gestureDetails = state.gestureDetails;
    if (gestureDetails == null) return;

    final currentScale = gestureDetails.totalScale ?? 1.0;
    final screenSize = MediaQuery.of(context).size;
    final imageSize = imageUrl != null ? getCachedImageSize(imageUrl) : null;

    // 计算目标缩放比例
    final targetScale = DoubleTapZoomController.calculateTargetScale(
      currentScale: currentScale,
      screenSize: screenSize,
      imageSize: imageSize,
    );

    state.animateDoubleTapZoom(
      targetScale: targetScale,
      doubleTapPosition: pointerDownPosition,
    );
  }
}
