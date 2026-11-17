import 'package:material_ui/material_ui.dart';

/// 懒加载作用域
///
/// 在页面级别提供缓存，页面销毁时缓存自动清理
class LazyLoadScope extends StatefulWidget {
  final Widget child;

  const LazyLoadScope({super.key, required this.child});

  /// 获取当前作用域的缓存
  static Set<String>? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_LazyLoadScopeData>()?.cache;
  }

  /// 检查 key 是否已加载（如果没有作用域则返回 false）
  static bool isLoaded(BuildContext context, String key) {
    return of(context)?.contains(key) ?? false;
  }

  /// 标记 key 已加载
  static void markLoaded(BuildContext context, String key) {
    of(context)?.add(key);
  }

  @override
  State<LazyLoadScope> createState() => _LazyLoadScopeState();
}

class _LazyLoadScopeState extends State<LazyLoadScope> {
  final Set<String> _cache = {};

  @override
  Widget build(BuildContext context) {
    return _LazyLoadScopeData(
      cache: _cache,
      child: widget.child,
    );
  }
}

class _LazyLoadScopeData extends InheritedWidget {
  final Set<String> cache;

  const _LazyLoadScopeData({
    required this.cache,
    required super.child,
  });

  @override
  bool updateShouldNotify(_LazyLoadScopeData oldWidget) => false;
}
