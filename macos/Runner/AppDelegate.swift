import Cocoa
import FlutterMacOS
import WebKit

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false  // 关闭窗口时不退出，保持 MessageBus 运行
  }

  // 点击 Dock 图标时重新显示窗口
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      super.applicationDidFinishLaunching(notification)
      return
    }

    // Raw Set-Cookie 写入通道
    let rawCookieChannel = FlutterMethodChannel(
      name: "com.fluxdo/raw_cookie",
      binaryMessenger: controller.engine.binaryMessenger
    )
    rawCookieChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setRawCookie":
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let rawSetCookie = args["rawSetCookie"] as? String,
              let url = URL(string: urlString) else {
          result(false)
          return
        }
        let headers = ["Set-Cookie": rawSetCookie]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard let cookie = cookies.first else {
          result(false)
          return
        }
        // 同时写入 HTTPCookieStorage.shared，配合 sharedCookiesEnabled
        // 确保 WKWebView 在创建时即可从 shared storage 读取到 cookie
        HTTPCookieStorage.shared.setCookie(cookie)
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.setCookie(cookie) {
          result(true)
        }

      // v0.4.0 Cookie 引擎新增原语
      // 设计依据: docs/cookie-sync-design-v0.4.0.md §5.4
      // 与 iOS AppDelegate.swift 实现一致 (WKHTTPCookieStore + HTTPCookieStorage.shared 跨 Apple 平台共享)

      case "nukeAllVariants":
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let name = args["name"] as? String,
              let pathCandidates = args["pathCandidates"] as? [String],
              let url = URL(string: urlString) else {
          result(0)
          return
        }
        let rawDomainCandidates = args["domainCandidates"] as? [Any] ?? []
        let domainCandidates: [String?] = rawDomainCandidates.map {
          $0 is NSNull ? nil : ($0 as? String)
        }
        AppDelegate.nukeAllVariantsApple(
          url: url,
          name: name,
          domainCandidates: domainCandidates,
          pathCandidates: pathCandidates,
          result: result
        )

      case "deleteExactCookie":
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let name = args["name"] as? String,
              let path = args["path"] as? String,
              let url = URL(string: urlString) else {
          result(false)
          return
        }
        let domain = args["domain"] as? String
        AppDelegate.deleteExactCookieApple(
          url: url,
          name: name,
          domain: domain,
          path: path,
          result: result
        )

      case "getAllCookieInfos":
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
          result([])
          return
        }
        AppDelegate.getAllCookieInfosApple(url: url, result: result)

      case "countCookiesByName":
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let name = args["name"] as? String,
              let url = URL(string: urlString) else {
          result(0)
          return
        }
        AppDelegate.countCookiesByNameApple(url: url, name: name, result: result)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.applicationDidFinishLaunching(notification)
  }

  // MARK: - Cookie 引擎 v0.4.0 原语 (Apple 平台共享实现)

  private static func matchDomain(cookieDomain: String, candidate: String?, host: String) -> Bool {
    let normalizedCookieDomain = (cookieDomain.hasPrefix(".")
      ? String(cookieDomain.dropFirst())
      : cookieDomain).lowercased()
    if let candidate = candidate {
      let normalizedCandidate = (candidate.hasPrefix(".")
        ? String(candidate.dropFirst())
        : candidate).lowercased()
      return normalizedCookieDomain == normalizedCandidate
    } else {
      return normalizedCookieDomain == host
    }
  }

  private static func nukeAllVariantsApple(
    url: URL,
    name: String,
    domainCandidates: [String?],
    pathCandidates: [String],
    result: @escaping FlutterResult
  ) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let matching = cookies.filter { cookie in
        guard cookie.name == name else { return false }
        let domainMatch = domainCandidates.contains { candidate in
          AppDelegate.matchDomain(cookieDomain: cookie.domain, candidate: candidate, host: host)
        }
        let pathMatch = pathCandidates.contains(cookie.path)
        return domainMatch && pathMatch
      }

      let group = DispatchGroup()
      let countLock = NSLock()
      var deletedCount = 0

      for cookie in matching {
        group.enter()
        store.delete(cookie) {
          countLock.lock()
          deletedCount += 1
          countLock.unlock()
          group.leave()
        }
      }

      let storage = HTTPCookieStorage.shared
      if let sharedCookies = storage.cookies {
        for cookie in sharedCookies where cookie.name == name {
          let domainMatch = domainCandidates.contains { candidate in
            AppDelegate.matchDomain(cookieDomain: cookie.domain, candidate: candidate, host: host)
          }
          let pathMatch = pathCandidates.contains(cookie.path)
          if domainMatch && pathMatch {
            storage.deleteCookie(cookie)
          }
        }
      }

      group.notify(queue: .main) {
        result(deletedCount)
      }
    }
  }

  private static func deleteExactCookieApple(
    url: URL,
    name: String,
    domain: String?,
    path: String,
    result: @escaping FlutterResult
  ) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let target = cookies.first { cookie in
        cookie.name == name &&
        cookie.path == path &&
        AppDelegate.matchDomain(cookieDomain: cookie.domain, candidate: domain, host: host)
      }
      guard let cookie = target else {
        DispatchQueue.main.async { result(false) }
        return
      }

      let group = DispatchGroup()
      group.enter()
      store.delete(cookie) {
        group.leave()
      }

      let storage = HTTPCookieStorage.shared
      if let sharedCookies = storage.cookies {
        for sharedCookie in sharedCookies where
          sharedCookie.name == name &&
          sharedCookie.path == path &&
          AppDelegate.matchDomain(cookieDomain: sharedCookie.domain, candidate: domain, host: host) {
          storage.deleteCookie(sharedCookie)
        }
      }

      group.notify(queue: .main) {
        result(true)
      }
    }
  }

  private static func getAllCookieInfosApple(url: URL, result: @escaping FlutterResult) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let applicable = cookies.filter { cookie in
        let cookieDomain = (cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst())
          : cookie.domain).lowercased()
        return host == cookieDomain || host.hasSuffix("." + cookieDomain)
      }

      let infos: [[String: Any?]] = applicable.map { cookie in
        return [
          "name": cookie.name,
          "value": cookie.value,
          "domain": cookie.domain,
          "path": cookie.path,
          "isSecure": cookie.isSecure,
          "isHttpOnly": cookie.isHTTPOnly,
          "expiresMillis": cookie.expiresDate.map { Int($0.timeIntervalSince1970 * 1000) },
        ]
      }

      DispatchQueue.main.async {
        result(infos)
      }
    }
  }

  private static func countCookiesByNameApple(url: URL, name: String, result: @escaping FlutterResult) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      let count = cookies.filter { cookie in
        guard cookie.name == name else { return false }
        let cookieDomain = (cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst())
          : cookie.domain).lowercased()
        return host == cookieDomain || host.hasSuffix("." + cookieDomain)
      }.count

      DispatchQueue.main.async {
        result(count)
      }
    }
  }
}
