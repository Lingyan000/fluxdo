// ignore_for_file: prefer_final_fields, overridden_fields, always_put_control_body_on_new_line

part of 'official.dart';

class _ExtendedPagePosition extends _PagePosition {
  _ExtendedPagePosition({
    required super.physics,
    required super.context,
    super.initialPage = 0,
    super.keepPage = true,
    super.viewportFraction = 1.0,
    super.oldPosition,
    double pageSpacing = 0.0,
  }) : _pageSpacing = pageSpacing;
  double _pageSpacing;
  double get pageSpacing => _pageSpacing;
  set pageSpacing(double value) {
    if (_pageSpacing != value) {
      final double? oldPage = page;
      _pageSpacing = value;
      if (oldPage != null) forcePixels(getPixelsFromPage(oldPage));
    }
  }

  double get _viewportWithoutSpacing => super.viewportDimension;

  // 翻页吸附使用含页间距的距离。
  @override
  double get viewportDimension => _viewportWithoutSpacing + pageSpacing;

  @override
  void absorb(ScrollPosition other) {
    super.absorb(other);
    if (other is _ExtendedPagePosition && other.hasViewportDimension) {
      // ScrollPosition.absorb 通过公开的 viewportDimension 复制尺寸，已包含旧页间距。
      // 底层布局只存实际视口，否则重建后会重复加间距，让非首页的图片向右移。
      super.applyViewportDimension(other._viewportWithoutSpacing);
    }
  }

  @override
  bool applyViewportDimension(double viewportDimension) {
    final oldViewport = hasViewportDimension ? _viewportWithoutSpacing : null;
    if (viewportDimension == oldViewport) {
      return true;
    }

    final double? oldPixels = hasPixels ? pixels : null;
    // 先用旧视口的完整翻页距离记住位置，再把同一页映射到新视口。
    final page =
        _cachedPage ??
        (oldPixels != null && oldViewport != null && oldViewport > 0
            ? getPageFromPixels(oldPixels, this.viewportDimension)
            : _pageToUseOnStartup);
    final bool result = super.applyViewportDimension(viewportDimension);
    final double newPixels = getPixelsFromPage(page);

    // If the viewportDimension is zero, cache the page
    // in case the viewport is resized to be non-zero.
    _cachedPage = (viewportDimension == 0.0) ? page : null;
    if (newPixels != oldPixels) {
      correctPixels(newPixels);
      return false;
    }
    return result;
  }
}
