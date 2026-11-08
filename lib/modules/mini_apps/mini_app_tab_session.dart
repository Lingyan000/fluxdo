import '../../services/auth_session.dart';
import '../../services/browser_tabs.dart';
import '../../services/embedded_browser_controller_pool.dart';
import '../../utils/platform_utils.dart';
import 'mini_app.dart';
import 'mini_app_engine.dart';
import 'mini_app_media_lifecycle.dart';

/// 仅用户主动收起时进入可见底栏。关闭释放原生实例，卡片不拥有隐藏页面。
class MiniAppTabSession extends BrowserTabSession {
  MiniAppTabSession({
    required this.details,
    required this.entry,
    required this.engine,
  }) : super(
         url: entry.toString(),
         title: details.app.name,
         accountGeneration: AuthSession().generation,
       );

  MiniAppDetails details;
  final Uri entry;
  MiniAppEngine engine;
  String? lightweightHtml;
  bool recorded = false;
  bool preferPanel = false;
  EmbeddedBrowserLease? browserLease;
  void Function()? onRevoked;
  MiniAppMediaLifecycle mediaLifecycle = MiniAppMediaLifecycle();
  @override
  bool get supportsDragRestore => !PlatformUtils.isDesktop;

  /// Windows 的槽位跟随原生实例，而非临时挂载页面的路由。
  bool acquireBrowserLease() {
    browserLease ??= EmbeddedBrowserControllerPool.instance.tryAcquire(
      priority: EmbeddedBrowserPriority.iframe,
      onRevoked: () {
        browserLease = null;
        onRevoked?.call();
      },
    );
    return browserLease != null;
  }

  @override
  Future<void> close() async {
    mediaLifecycle.dispose();
    await super.close();
    browserLease?.release();
    browserLease = null;
    onRevoked = null;
    lightweightHtml = null;
  }

  @override
  Future<void> discardWebView() async {
    mediaLifecycle.dispose();
    await super.discardWebView();
    if (!isClosed) mediaLifecycle = MiniAppMediaLifecycle();
  }
}
