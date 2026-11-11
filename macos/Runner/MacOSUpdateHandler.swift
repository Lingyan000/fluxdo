import Cocoa
import FlutterMacOS
import Sparkle

final class MacOSUpdateHandler: NSObject, SPUUpdaterDelegate {
  static let shared = MacOSUpdateHandler()
  private let skippedVersionKey = "FluxDOSkippedUpdateVersion"
  private var controller: SPUStandardUpdaterController?
  private var githubProxy = ""

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.fluxdo/macos_update", binaryMessenger: messenger)
    channel.setMethodCallHandler { [self] call, result in
      if call.method == "isVersionSkipped", let version = call.arguments as? String {
        result(UserDefaults.standard.string(forKey: skippedVersionKey) == version)
        return
      }
      guard call.method == "checkForUpdates" else {
        result(FlutterMethodNotImplemented)
        return
      }
      #if DEBUG
      // 开发构建继续跳转发布页，避免覆盖工作区内的构建产物。
      result(false)
      #else
      // 同一轮更新固定使用同一个代理，避免改变正在下载的任务。
      if controller?.updater.sessionInProgress == true {
        result(true)
        return
      }
      let args = call.arguments as? [String: String]
      githubProxy = (args?["githubProxy"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !githubProxy.isEmpty {
        guard let proxy = URL(string: githubProxy),
              ["https", "http"].contains(proxy.scheme?.lowercased() ?? ""),
              proxy.host != nil else {
          result(FlutterError(code: "invalid_proxy", message: "Invalid GitHub proxy URL.", details: nil))
          return
        }
        if !githubProxy.hasSuffix("/") { githubProxy += "/" }
      }
      do {
        if controller == nil {
          let updater = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
          )
          try updater.updater.start()
          controller = updater
        }
        controller?.checkForUpdates(nil)
        result(true)
      } catch {
        result(FlutterError(code: "updater_unavailable", message: error.localizedDescription, details: nil))
      }
      #endif
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "x86_64"
    #endif
    return proxied("https://github.com/Lingyan000/fluxdo/releases/latest/download/appcast-macos-\(architecture).xml")
  }

  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
               with request: NSMutableURLRequest) {
    guard let url = request.url, url.host?.lowercased() == "github.com" else { return }
    request.url = URL(string: proxied(url.absoluteString))
  }

  func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
               forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
    // Flutter 负责启动提醒，也需遵循原生更新界面中的跳过选择。
    if choice == .skip {
      UserDefaults.standard.set(item.displayVersionString, forKey: skippedVersionKey)
    } else if choice == .install {
      UserDefaults.standard.removeObject(forKey: skippedVersionKey)
    }
  }

  private func proxied(_ url: String) -> String {
    githubProxy.isEmpty || url.hasPrefix(githubProxy) ? url : githubProxy + url
  }
}
