import Foundation
import WebKit

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
    guard let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          value.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil else { return nil }
    return value
  }

  /// 不可读时明确为未知；WebKit 构建号和系统版本不能冒充 Safari 产品版本。
  static func diagnostics() -> [String: Any] {
    let version = safariVersion()
    let webkit = Bundle(for: WKWebView.self)
    return [
      "safari_product_version": version as Any? ?? NSNull(),
      "safari_version_verified": version != nil,
      "safari_version_source": version == nil ? "unavailable" : "safari_bundle",
      "safari_read_status": version == nil ? "metadata_unavailable_or_invalid" : "read",
      "webkit_bundle_version": webkit.object(forInfoDictionaryKey: "CFBundleVersion") as Any? ?? NSNull(),
      "webkit_short_version": webkit.object(forInfoDictionaryKey: "CFBundleShortVersionString") as Any? ?? NSNull(),
      "os_version": ProcessInfo.processInfo.operatingSystemVersionString
    ]
  }
}
