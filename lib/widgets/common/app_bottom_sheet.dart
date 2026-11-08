import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:common_ui/common_ui.dart';

import '../../providers/shortcut_provider.dart';
import '../../utils/dialog_utils.dart';

// AppSheetScaffold / AppSheetStyle 已下沉到 common_ui(主 app 与子包共用);
// 这里 re-export,让现有 `import '.../app_bottom_sheet.dart'` 的代码无需改动
// 即可继续拿到外壳组件。
export 'package:common_ui/common_ui.dart' show AppSheetScaffold, AppSheetStyle;

/// 底部弹框统一入口。内部走 [showAppBottomSheet](带背景模糊与快捷键 surface),
/// 固定 `isScrollControlled: true` + 透明背景,并自动包裹 [AppSheetScaffold]。
///
/// 入口依赖主 app 的偏好(模糊)与快捷键 surface,因此留在主 app;外壳组件
/// [AppSheetScaffold] 是纯 UI、零依赖,放在 common_ui 供子包共用。
abstract final class AppBottomSheet {
  /// 弹出统一外壳的底部弹框。内容由 [builder] 返回,无需自绘外壳。
  ///
  /// 高度随内容自适应,超过 [maxHeightFactor] 占屏比后由内容自身滚动。
  static Future<T?> show<T>({
    required BuildContext context,
    AppSheetStyle style = AppSheetStyle.edge,
    String? title,
    Widget? titleWidget,
    List<Widget> actions = const [],
    bool showCloseButton = true,
    bool? showDragHandle,
    bool showTitleDivider = false,
    EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(
      16,
      0,
      16,
      16,
    ),
    double maxHeightFactor = 0.9,
    bool isDismissible = true,
    bool enableDrag = true,
    bool blur = true,
    ValueChanged<double>? onBlurSigmaChanged,
    ValueListenable<bool>? blurReady,
    bool filterBackdrop = true,
    ShortcutSurfaceConfig? shortcutSurface,
    Widget? footer,
    required WidgetBuilder builder,
  }) {
    return showAppBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: isDismissible,
      // 表单卡片式禁止下滑关闭,避免误关丢失输入(列表式保留下滑关闭)
      enableDrag: style == AppSheetStyle.card ? false : enableDrag,
      blur: blur,
      onBlurSigmaChanged: onBlurSigmaChanged,
      blurReady: blurReady,
      filterBackdrop: filterBackdrop,
      shortcutSurface: shortcutSurface,
      builder: (ctx) => AppSheetScaffold(
        style: style,
        title: title,
        titleWidget: titleWidget,
        actions: actions,
        showCloseButton: showCloseButton,
        showDragHandle: showDragHandle,
        showTitleDivider: showTitleDivider,
        contentPadding: contentPadding,
        maxHeightFactor: maxHeightFactor,
        footer: footer,
        child: Builder(builder: builder),
      ),
    );
  }

  /// 弹出可拖拽缩放的底部弹框(基于 [DraggableScrollableSheet])。
  ///
  /// [bodyBuilder] 收到的 `scrollController` 必须交给内容里的可滚动组件,
  /// 才能支持「下拉收起 / 上拉放大」的联动。内容若是「固定头 + 列表」结构,
  /// 通常传 `contentPadding: EdgeInsets.zero` 由内容自管内边距。
  static Future<T?> showDraggable<T>({
    required BuildContext context,
    String? title,
    Widget? titleWidget,
    List<Widget> actions = const [],
    bool showCloseButton = false,
    bool showDragHandle = true,
    bool showTitleDivider = false,
    EdgeInsetsGeometry contentPadding = EdgeInsets.zero,
    double initialSize = 0.7,
    double minSize = 0.5,
    double maxSize = 0.95,
    bool blur = true,
    ShortcutSurfaceConfig? shortcutSurface,
    Widget? footer,
    required Widget Function(
      BuildContext context,
      ScrollController scrollController,
    )
    bodyBuilder,
  }) {
    return showAppBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      blur: blur,
      shortcutSurface: shortcutSurface,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: initialSize,
        minChildSize: minSize,
        maxChildSize: maxSize,
        expand: false,
        builder: (context, scrollController) => AppSheetScaffold(
          title: title,
          titleWidget: titleWidget,
          actions: actions,
          showCloseButton: showCloseButton,
          showDragHandle: showDragHandle,
          showTitleDivider: showTitleDivider,
          contentPadding: contentPadding,
          expandToFill: true,
          footer: footer,
          child: bodyBuilder(context, scrollController),
        ),
      ),
    );
  }
}
