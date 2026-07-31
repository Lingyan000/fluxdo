import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:window_manager/window_manager.dart';

import '../../../providers/preferences_provider.dart';
import '../../../utils/layout_lock.dart';
import '../../../utils/platform_utils.dart';

/// 视频全屏的 LayoutLock / 屏幕方向 / 系统全屏时序治理,常驻单例。
///
/// 旧方案把这些回调(WidgetsBindingObserver + WindowListener)撒在每个
/// 播放器 State 上,导致「宿主 State 必须活到退出全屏回调来临」——为此
/// 才有 wantKeepAlive 钉住列表项那套。收拢进常驻单例后宿主死活无所谓。
///
/// 时序语义(照搬旧 video_builder 的实测结论):
/// - 进全屏:先 LayoutLock.acquire() 冻结底层双栏/单栏判定,再改方向/
///   系统全屏 —— 防横屏导致底层页面重新布局;桌面端 setFullScreen 延迟
///   一帧,确保全屏路由已推入后再触发窗口变化。
/// - 退全屏:LayoutLock 不能立即释放,要等屏幕尺寸真正恢复:
///   移动端等 didChangeMetrics(方向恢复触发),桌面端等
///   onWindowLeaveFullScreen(窗口退出全屏动画完成);恢复期间释放会让
///   布局切换发生在尺寸还没回来的窗口里。另设超时兜底,防回调丢失把
///   布局永久锁死。
class FullscreenMediaCoordinator with WidgetsBindingObserver, WindowListener {
  FullscreenMediaCoordinator._();

  static final FullscreenMediaCoordinator instance =
      FullscreenMediaCoordinator._();

  static final bool _isDesktop = PlatformUtils.isDesktop;

  bool _active = false;
  bool _pendingLockRelease = false;
  Timer? _releaseTimeout;

  /// 进入全屏。返回后才可推全屏路由(移动端方向切换已下发)。
  Future<void> enter({required bool landscape}) async {
    if (_active) return;
    _active = true;
    // 若上一次退出的延迟释放还在等回调,先了结,避免计数越锁越多
    _finishPendingRelease();
    LayoutLock.acquire();
    if (_isDesktop) {
      windowManager.addListener(this);
      // 延迟到下一帧,确保全屏路由已推入后再触发窗口变化
      WidgetsBinding.instance.addPostFrameCallback((_) {
        windowManager.setFullScreen(true);
      });
    } else {
      WidgetsBinding.instance.addObserver(this);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (landscape) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    }
  }

  /// 退出全屏(全屏路由 pop 后调用)。LayoutLock 延迟到尺寸恢复再释放。
  Future<void> exit() async {
    if (!_active) return;
    _active = false;
    _pendingLockRelease = true;
    // 兜底:didChangeMetrics / onWindowLeaveFullScreen 若丢失(如系统
    // 行为差异),3s 后强制释放,防布局判定被永久冻结
    _releaseTimeout?.cancel();
    _releaseTimeout = Timer(const Duration(seconds: 3), _finishPendingRelease);
    if (_isDesktop) {
      windowManager.setFullScreen(false);
    } else {
      // 竖滑亮度手势改的是 app 级亮度,不随全屏退出自动复原,必须
      // 显式 reset 回系统值 —— 否则整个 app 都停留在调过的亮度
      unawaited(
        ScreenBrightness()
            .resetApplicationScreenBrightness()
            .catchError((_) {}),
      );
      // 状态栏恢复不能直接切 edgeToEdge:Flutter 3.41+ 引擎在
      // EDGE_TO_EDGE 分支不清除 immersiveSticky 设置的
      // SYSTEM_UI_FLAG_FULLSCREEN/HIDE_NAVIGATION,bars 回不来。
      // 先 manual+all overlays 显式清 immersive flags 并显示 bars,
      // 再切回 edgeToEdge 恢复全局 edge-to-edge 布局
      // (同 ImageViewerPage._restoreSystemUI 的实测结论)。
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // 先放开全方向,再由 restoreOrientationLock 按用户设置收回竖屏
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  @override
  void didChangeMetrics() {
    // 移动端:退出全屏后方向恢复,屏幕尺寸变化触发此回调,可安全释放
    if (_pendingLockRelease && !_isDesktop) {
      // 延迟一帧确保恢复布局稳定后再解锁
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _finishPendingRelease();
      });
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    // 桌面端:窗口退出全屏动画完成,安全释放
    if (_pendingLockRelease) {
      _finishPendingRelease();
    }
  }

  void _finishPendingRelease() {
    _releaseTimeout?.cancel();
    _releaseTimeout = null;
    if (!_pendingLockRelease) return;
    _pendingLockRelease = false;
    LayoutLock.release();
    if (_isDesktop) {
      windowManager.removeListener(this);
    } else {
      WidgetsBinding.instance.removeObserver(this);
      // 恢复竖屏锁定(退出全屏时放开了全方向)
      unawaited(PreferencesNotifier.restoreOrientationLock());
    }
  }
}
