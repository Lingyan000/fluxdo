import 'package:flutter/widgets.dart';

/// 为底栏让出槽高，用于挂在 tab 页内层 Scaffold 上的 FAB。
///
/// AdaptiveScaffold 以 extendBody 把 tab 页延伸到底栏后面：body 的
/// padding.bottom 含底栏槽高，viewPadding 只保留系统安全区。Scaffold
/// 定位 FAB 只认 viewPadding，不补差值就会被底栏盖住。作为独立路由
/// 打开时两者相等，差值为 0，不影响位置。
///
/// [mediaQuery] 必须从内层 Scaffold 外的页面 context 读取并传入。
/// Scaffold 会清除 FAB 子树的 padding，在本组件 build 中读取时
/// 已经丢失底栏槽高，无法计算避让距离。
class BottomNavClearance extends StatelessWidget {
  const BottomNavClearance({
    super.key,
    required this.mediaQuery,
    required this.child,
  });

  final MediaQueryData mediaQuery;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final clearance =
        (mediaQuery.padding.bottom - mediaQuery.viewPadding.bottom).clamp(
          0.0,
          double.infinity,
        );
    if (clearance == 0) return child;
    return Padding(
      padding: EdgeInsets.only(bottom: clearance),
      child: child,
    );
  }
}
