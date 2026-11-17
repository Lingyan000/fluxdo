import 'package:material_ui/material_ui.dart';
import '../../utils/responsive.dart';

/// 响应式列表/网格组件
/// 手机上显示为列表，平板上显示为网格
class ResponsiveListView extends StatelessWidget {
  const ResponsiveListView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.tabletCrossAxisCount = 2,
    this.desktopCrossAxisCount = 3,
    this.childAspectRatio = 2.5,
    this.crossAxisSpacing = 12,
    this.mainAxisSpacing = 0,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;

  /// 平板上的列数
  final int tabletCrossAxisCount;

  /// 桌面上的列数
  final int desktopCrossAxisCount;

  /// 网格项的宽高比
  final double childAspectRatio;

  /// 网格列间距
  final double crossAxisSpacing;

  /// 网格行间距
  final double mainAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final deviceType = Responsive.getDeviceType(context);

    if (deviceType == DeviceType.mobile) {
      return ListView.builder(
        controller: controller,
        padding: padding,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
      );
    }

    // 平板/桌面使用网格
    final crossAxisCount = deviceType == DeviceType.desktop
        ? desktopCrossAxisCount
        : tabletCrossAxisCount;

    return GridView.builder(
      controller: controller,
      padding: padding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: crossAxisSpacing,
        mainAxisSpacing: mainAxisSpacing,
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }
}

/// 响应式 Sliver 列表/网格
class ResponsiveSliverList extends StatelessWidget {
  const ResponsiveSliverList({
    super.key,
    required this.delegate,
    this.tabletCrossAxisCount = 2,
    this.desktopCrossAxisCount = 3,
    this.crossAxisSpacing = 12,
    this.mainAxisSpacing = 0,
  });

  final SliverChildDelegate delegate;
  final int tabletCrossAxisCount;
  final int desktopCrossAxisCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final deviceType = Responsive.getDeviceType(context);

    if (deviceType == DeviceType.mobile) {
      return SliverList(delegate: delegate);
    }

    final crossAxisCount = deviceType == DeviceType.desktop
        ? desktopCrossAxisCount
        : tabletCrossAxisCount;

    return SliverGrid(
      delegate: delegate,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: crossAxisSpacing,
        mainAxisSpacing: mainAxisSpacing,
        // 让子项自适应高度需要额外处理
        childAspectRatio: 2.5,
      ),
    );
  }
}
