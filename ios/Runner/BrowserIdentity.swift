import Foundation

/// 读取 Safari 自身公开的版本元数据，不从冻结的 UA 或系统版本推导。
enum BrowserIdentity {
  static func safariVersion() -> String? {
    #if targetEnvironment(simulator)
    guard let root = ProcessInfo.processInfo.environment["SIMULATOR_ROOT"] else { return nil }
    let path = root + "/Applications/MobileSafari.app"
    #else
    let path = "/Applications/MobileSafari.app"
    #endif
    guard let bundle = Bundle(path: path),
          bundle.bundleIdentifier == "com.apple.mobilesafari" else { return nil }
    return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }
}
