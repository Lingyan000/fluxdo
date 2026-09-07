import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 崩溃 / ANR 现场的上下文标注(当前页面栈)。
///
/// 背景:线上 ANR 与 native 崩溃的事件里,`customKeys` 一直是空的 —— 只能
/// 看到系统栈,看不到"用户当时在哪个页面"。`nativeSurfaceChanged` 型 ANR
/// 的主线程栈全是 framework 帧,没有任何业务信息,归因只能靠猜。
///
/// 这里把当前路由(以及最近几步导航)同步给原生侧,写进 Crashlytics 的
/// custom keys。崩溃/ANR 发生时,现场自带"在哪个页面、怎么走到这儿的"。
///
/// 仅 Android 有 Crashlytics 集成;其他平台整体 no-op。
class CrashContextReporter {
  CrashContextReporter._();

  static const MethodChannel _channel =
      MethodChannel('com.github.lingyan000.fluxdo/crashlytics');

  /// 最近的导航轨迹(最新在末尾),给现场一点"怎么走到这儿"的上下文。
  static final List<String> _trail = [];
  static const int _trailMax = 8;

  /// 由设置开关驱动:用户关掉崩溃采集时不再发送任何内容。
  static bool _enabled = false;

  static void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// 记一步导航并同步当前页面。
  static void noteRoute(String action, String routeName) {
    if (!_enabled) return;
    _trail.add('$action $routeName');
    while (_trail.length > _trailMax) {
      _trail.removeAt(0);
    }
    _send(routeName);
  }

  static void _send(String current) {
    if (!_enabled) return;
    // fire-and-forget:上报失败不能影响导航
    _channel.invokeMethod<void>('setCrashContext', {
      'route': current,
      'routeTrail': _trail.join(' > '),
    }).catchError((Object e) {
      if (kDebugMode) {
        debugPrint('[CrashContext] 同步失败: $e');
      }
    });
  }
}

/// 把导航事件喂给 [CrashContextReporter]。
///
/// 路由名取值优先级:
/// 1. `settings.name` —— 显式命名的路由(本项目仅少数几处);
/// 2. 承载 widget 的运行时类型 —— 绝大多数页面是直接 push
///    `MaterialPageRoute(builder: (_) => XxxPage())`,`settings.name` 为
///    null,此时 widget 类型名(如 `TopicDetailPage`)才是有效信息;
/// 3. 兜底为路由类型名。
class CrashContextNavObserver extends NavigatorObserver {
  String _desc(Route<dynamic>? route) {
    if (route == null) return '-';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    if (route is ModalRoute) {
      // buildPage 在此阶段调用不安全(需要 context/animation),改用
      // 已挂载的 subtree 类型:PageRoute 的 child 类型即页面类型。
      final widget = _pageWidgetOf(route);
      if (widget != null) return widget;
    }
    return route.runtimeType.toString();
  }

  /// 取 ModalRoute 承载页面的 widget 类型名。
  ///
  /// Flutter 没有公开 API 直接拿 PageRoute 的 child,但 route 挂载后其
  /// `subtreeContext` 指向页面根 Element,`widget.runtimeType` 即所需。
  /// 未挂载(didPush 早于首帧)时返回 null,由调用方回退。
  String? _pageWidgetOf(ModalRoute<dynamic> route) {
    try {
      final ctx = route.subtreeContext;
      if (ctx == null) return null;
      // subtreeContext 指向 _ModalScope 一类的内部包装,向下找第一个
      // 非私有(不以 _ 开头)的 widget 类型,即业务页面。
      String? found;
      void visit(Element element) {
        if (found != null) return;
        final type = element.widget.runtimeType.toString();
        if (!type.startsWith('_') &&
            !_frameworkWidgets.contains(type) &&
            type.isNotEmpty) {
          found = type;
          return;
        }
        element.visitChildren(visit);
      }

      (ctx as Element).visitChildren(visit);
      return found;
    } catch (_) {
      return null;
    }
  }

  /// 页面根部常见的框架包装,跳过它们才能找到真正的业务页面类型。
  static const Set<String> _frameworkWidgets = {
    'Semantics',
    'FocusScope',
    'Focus',
    'RepaintBoundary',
    'AnimatedBuilder',
    'Builder',
    'ExcludeFocus',
    'PageStorage',
    'Offstage',
    'IgnorePointer',
    'FadeTransition',
    'SlideTransition',
    'CupertinoPageTransition',
    'MaterialPageTransition',
    'AnimatedWidget',
    'KeyedSubtree',
    'ProviderScope',
    'UncontrolledProviderScope',
    'TranslationProvider',
  };

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // didPush 时 subtree 尚未挂载,延到首帧后再取(拿得到 widget 类型)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CrashContextReporter.noteRoute('push', _desc(route));
    });
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    CrashContextReporter.noteRoute('pop→', _desc(previousRoute));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CrashContextReporter.noteRoute('replace', _desc(newRoute));
    });
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    CrashContextReporter.noteRoute('remove→', _desc(previousRoute));
  }
}
