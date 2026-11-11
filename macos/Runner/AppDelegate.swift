import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false  // 关闭窗口时不退出，保持 MessageBus 运行
  }

  // 点击 Dock 图标时重新显示窗口
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      // 已关闭的子窗口可能仍被插件引用，Dock 唤起只恢复社区主窗口。
      mainFlutterWindow?.makeKeyAndOrderFront(self)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // 注意: com.fluxdo/raw_cookie channel 和其它 cookie 相关 channel 一起
  // 注册在 MainFlutterWindow.awakeFromNib (见 MainFlutterWindow.swift)。
  // 不要在 applicationDidFinishLaunching 注册 channel ——
  // 该时机 mainFlutterWindow?.contentViewController 可能还未就绪,
  // channel 注册会被静默跳过, Dart 端调用收到 MissingPluginException。
}
