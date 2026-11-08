import '../../widgets/browser/browser_page_route.dart';

/// 网页和小程序共用收起转场，正常打开与返回仍遵循平台导航。
class MinimizablePageRoute<T> extends BrowserPageRoute<T> {
  MinimizablePageRoute({
    required super.builder,
    required super.name,
    super.fromDock,
    super.motion,
    super.session,
  });
}
