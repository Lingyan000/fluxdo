import Flutter
import SafariServices
import UIKit
import WebKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 注册 iOS 后台任务 handler（必须在 didFinishLaunchingWithOptions 返回前调用）
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "com.fluxdo.notificationPoll", frequency: nil)

    // 注册 cookie 同步 channel，用于将 cookie 写入 HTTPCookieStorage.shared
    // WKWebView 的 sharedCookiesEnabled 在创建时从 HTTPCookieStorage.shared 读取 cookie
    if let controller = window?.rootViewController as? FlutterViewController {
      // 媒体转码通道(音视频压缩到 4MB:AVAssetWriter 硬编,零依赖)
      MediaTranscodeHandler.shared.register(
        messenger: controller.binaryMessenger
      )
      // 注册代理 CA 证书 channel（原生层 SSL challenge 拦截）
      let proxyCertChannel = FlutterMethodChannel(
        name: "com.fluxdo/proxy_cert",
        binaryMessenger: controller.binaryMessenger
      )
      proxyCertChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "setCaCertPem":
          guard let pem = call.arguments as? String else {
            result(false)
            return
          }
          DohProxyCertHandler.shared.setCaCertPem(pem)
          result(true)
        case "clear":
          DohProxyCertHandler.shared.clearCaCert()
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      // 注册描述文件安装 channel
      let profileChannel = FlutterMethodChannel(
        name: "com.fluxdo/profile_install",
        binaryMessenger: controller.binaryMessenger
      )
      profileChannel.setMethodCallHandler { [weak self] (call, result) in
        switch call.method {
        case "installProfile":
          guard let mobileconfig = call.arguments as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected mobileconfig string", details: nil))
            return
          }
          self?.serveMobileconfigViaSafari(mobileconfig) { success in
            result(success)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      // 注册浏览器 channel（应用链接解析与启动）
      let browserChannel = FlutterMethodChannel(
        name: "com.github.lingyan000.fluxdo/browser",
        binaryMessenger: controller.binaryMessenger
      )
      browserChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "resolveAppLink":
          // iOS 无法获取目标应用的名称和图标
          result(["canResolve": false, "appName": nil, "packageName": nil, "appIcon": nil])

        case "launchAppLink":
          guard let args = call.arguments as? [String: Any],
                let urlString = args["url"] as? String,
                let url = URL(string: urlString) else {
            result(false)
            return
          }
          UIApplication.shared.open(url, options: [:]) { success in
            result(success)
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let appIconChannel = FlutterMethodChannel(
        name: "com.github.lingyan000.fluxdo/app_icon",
        binaryMessenger: controller.binaryMessenger
      )
      appIconChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "supportsAlternateIcons":
          if #available(iOS 10.3, *) {
            result(UIApplication.shared.supportsAlternateIcons)
          } else {
            result(false)
          }

        case "getAlternateIconName":
          if #available(iOS 10.3, *) {
            result(UIApplication.shared.alternateIconName)
          } else {
            result(nil)
          }

        case "setAlternateIcon":
          guard #available(iOS 10.3, *) else {
            result(FlutterError(code: "UNAVAILABLE", message: "Alternate icons require iOS 10.3+", details: nil))
            return
          }

          let args = call.arguments as? [String: Any]
          let iconName = args?["iconName"] as? String
          self.setAlternateIcon(iconName, result: result)

        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let channel = FlutterMethodChannel(
        name: "com.fluxdo/cookie_storage",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] (call, result) in
        switch call.method {
        case "setCookies":
          guard let args = call.arguments as? [[String: Any?]] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected list of cookie maps", details: nil))
            return
          }
          self?.setCookiesToSharedStorage(args)
          result(true)
        case "clearCookies":
          let url = (call.arguments as? String) ?? ""
          self?.clearCookiesFromSharedStorage(url: url)
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }


      // Raw Set-Cookie 写入通道
      // 用 HTTPCookie.cookies(withResponseHeaderFields:for:) 从原始头构造 cookie
      // 保留 host-only 等完整语义
      let rawCookieChannel = FlutterMethodChannel(
        name: "com.fluxdo/raw_cookie",
        binaryMessenger: controller.binaryMessenger
      )

      // Cookie store 变化观察通道 (Phase B)
      // 注册 WKHTTPCookieStoreObserver, WV 网络层等外部修改 cookie 时
      // 通知 Dart 端 sweep。internalWriteCount > 0 时 observer 忽略,
      // 避免我们自己 setCookie/delete 导致 sweep 循环。
      let cookieObserverChannel = FlutterMethodChannel(
        name: "com.fluxdo/cookie_observer",
        binaryMessenger: controller.binaryMessenger
      )
      CookieStoreObserverHandler.shared.attach(channel: cookieObserverChannel)

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
          let writeSharedStorage = args["writeSharedStorage"] as? Bool ?? true
          CookieStoreObserverHandler.shared.beginInternalWrite()
          let storage = HTTPCookieStorage.shared
          if writeSharedStorage {
            // 同时写入 HTTPCookieStorage.shared，配合 sharedCookiesEnabled
            // 确保 WKWebView 在创建时即可从 shared storage 读取到 cookie。
            storage.setCookie(cookie)
          } else {
            AppDelegate.deleteSharedCookieIOS(storage: storage, url: url, cookie: cookie)
          }
          let store = WKWebsiteDataStore.default().httpCookieStore
          store.setCookie(cookie) {
            CookieStoreObserverHandler.shared.endInternalWrite()
            result(true)
          }

        // v0.4.0 Cookie 引擎新增原语
        // 设计依据: docs/cookie-sync-design-v0.4.0.md §5.4

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
          AppDelegate.nukeAllVariantsIOS(
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
          AppDelegate.deleteExactCookieIOS(
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
          AppDelegate.getAllCookieInfosIOS(url: url, result: result)

        case "countCookiesByName":
          guard let args = call.arguments as? [String: Any],
                let urlString = args["url"] as? String,
                let name = args["name"] as? String,
                let url = URL(string: urlString) else {
            result(0)
            return
          }
          AppDelegate.countCookiesByNameIOS(url: url, name: name, result: result)

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func isRequestedIconApplied(_ iconName: String?) -> Bool {
    if #available(iOS 10.3, *) {
      return UIApplication.shared.alternateIconName == iconName
    }
    return iconName == nil
  }

  private func makeAlternateIconError(
    message: String,
    application: UIApplication,
    iconName: String?,
    error: NSError? = nil
  ) -> FlutterError {
    var details: [String: Any] = [
      "applicationState": application.applicationState.rawValue,
      "currentIconName": application.alternateIconName as Any,
      "requestedIconName": iconName as Any,
      "systemVersion": UIDevice.current.systemVersion,
      "isSimulator": {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
      }(),
    ]

    if let error {
      details["domain"] = error.domain
      details["code"] = error.code
      details["userInfo"] = error.userInfo
    }

    return FlutterError(
      code: "SET_ICON_FAILED",
      message: message,
      details: details
    )
  }

  private func setAlternateIcon(_ iconName: String?, result: @escaping FlutterResult) {
    if #available(iOS 10.3, *) {
      let application = UIApplication.shared

      guard application.supportsAlternateIcons else {
        result(
          FlutterError(
            code: "UNSUPPORTED",
            message: "Alternate icons are not supported on this device.",
            details: [
              "applicationState": application.applicationState.rawValue,
              "currentIconName": application.alternateIconName as Any,
              "requestedIconName": iconName as Any,
            ]
          )
        )
        return
      }

      if isRequestedIconApplied(iconName) {
        result(application.alternateIconName)
        return
      }

      DispatchQueue.main.async {
        application.setAlternateIconName(iconName) { [weak self] error in
          guard let self else { return }

          if let error = error as NSError? {
            if self.isRequestedIconApplied(iconName) {
              result(application.alternateIconName)
              return
            }

            result(
              self.makeAlternateIconError(
                message: error.localizedDescription,
                application: application,
                iconName: iconName,
                error: error
              )
            )
          } else {
            result(application.alternateIconName)
          }
        }
      }
    } else {
      result(FlutterError(code: "UNAVAILABLE", message: "Alternate icons require iOS 10.3+", details: nil))
    }
  }

  /// 将 cookie 写入 HTTPCookieStorage.shared
  private func setCookiesToSharedStorage(_ cookieMaps: [[String: Any?]]) {
    let storage = HTTPCookieStorage.shared
    for map in cookieMaps {
      guard let name = map["name"] as? String,
            let value = map["value"] as? String,
            let urlString = map["url"] as? String else {
        continue
      }
      var properties: [HTTPCookiePropertyKey: Any] = [
        .originURL: urlString,
        .name: name,
        .value: value,
        .path: (map["path"] as? String) ?? "/",
      ]
      if let domain = map["domain"] as? String {
        properties[.domain] = domain
      } else if let host = URL(string: urlString)?.host {
        properties[.domain] = host
      }
      if let expiresMs = map["expiresDate"] as? Int, expiresMs > 0 {
        properties[.expires] = Date(timeIntervalSince1970: TimeInterval(Double(expiresMs) / 1000))
      }
      if let isSecure = map["isSecure"] as? Bool, isSecure {
        properties[.secure] = "TRUE"
      }
      if let isHttpOnly = map["isHttpOnly"] as? Bool, isHttpOnly {
        properties[.init("HttpOnly")] = "YES"
      }
      if let cookie = HTTPCookie(properties: properties) {
        storage.setCookie(cookie)
      }
    }
  }

  /// 清除 HTTPCookieStorage.shared 中指定 URL 的 cookie
  private func clearCookiesFromSharedStorage(url: String) {
    let storage = HTTPCookieStorage.shared
    guard let urlHost = URL(string: url)?.host else { return }
    if let cookies = storage.cookies {
      for cookie in cookies {
        if urlHost.hasSuffix(cookie.domain) || ".\(urlHost)".hasSuffix(cookie.domain) {
          storage.deleteCookie(cookie)
        }
      }
    }
  }

  // MARK: - Cookie 引擎 v0.4.0 原语
  //
  // 设计依据: docs/cookie-sync-design-v0.4.0.md §5.4
  //
  // 关键平台特性 (依据 §3.1 / §3.2 / §3.6):
  // - WKHTTPCookieStore 与 HTTPCookieStorage.shared 同步不可靠 → 双写双删
  // - WKHTTPCookieStore.delete completion 在 main queue 回调
  // - HTTPCookie.domain 对 host-only cookie 仍返回 host (无前导点)

  /// 把 HTTPCookie.sameSitePolicy 转成 Dart 端可识别的字符串 ("Lax"/"Strict"/"None")。
  /// iOS 13+/macOS 10.15+ 支持; 早期系统返回 nil。
  private static func sameSiteString(_ cookie: HTTPCookie) -> String? {
    if #available(iOS 13.0, *) {
      guard let policy = cookie.sameSitePolicy else { return nil }
      switch policy {
      case .sameSiteLax:
        return "Lax"
      case .sameSiteStrict:
        return "Strict"
      default:
        let raw = policy.rawValue.lowercased()
        if raw.contains("none") { return "None" }
        if raw.contains("lax") { return "Lax" }
        if raw.contains("strict") { return "Strict" }
        return nil
      }
    }
    return nil
  }

  /// domain 匹配规则 (用于 Sentinel 枚举/删除变体)
  ///
  /// - candidate 为 nil 表示 host-only 候选, 要求 cookie.domain == host
  /// - candidate 非 nil 时, 容忍前导点差异 (".example.com" 等价 "example.com")
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

  private static func deleteSharedCookieIOS(
    storage: HTTPCookieStorage,
    url: URL,
    cookie: HTTPCookie
  ) {
    let host = (url.host ?? "").lowercased()
    guard let sharedCookies = storage.cookies else { return }
    for sharedCookie in sharedCookies where
      sharedCookie.name == cookie.name &&
      sharedCookie.path == cookie.path &&
      AppDelegate.matchDomain(cookieDomain: sharedCookie.domain, candidate: cookie.domain, host: host) {
      storage.deleteCookie(sharedCookie)
    }
  }

  /// 暴力穷举删除指定 name 的所有变体 (WK store + HTTPCookieStorage.shared 双删)
  private static func nukeAllVariantsIOS(
    url: URL,
    name: String,
    domainCandidates: [String?],
    pathCandidates: [String],
    result: @escaping FlutterResult
  ) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let host = (url.host ?? "").lowercased()

    store.getAllCookies { cookies in
      // 枚举真实 cookie 对象，按 name + 适用域过滤（与 countCookiesByNameIOS 对齐），
      // 逐个 store.delete 真实对象。不再用 domainCandidates/pathCandidates 猜测，
      // 杜绝 "count 数得到、nuke 删不掉" 的残留循环。
      let matching = cookies.filter { cookie in
        guard cookie.name == name else { return false }
        let cookieDomain = (cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst())
          : cookie.domain).lowercased()
        return host == cookieDomain || host.hasSuffix("." + cookieDomain)
      }

      CookieStoreObserverHandler.shared.beginInternalWrite()
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

      // 双删: 同步清 HTTPCookieStorage.shared 中匹配的同名 cookie
      let storage = HTTPCookieStorage.shared
      if let sharedCookies = storage.cookies {
        for cookie in sharedCookies where cookie.name == name {
          let cookieDomain = (cookie.domain.hasPrefix(".")
            ? String(cookie.domain.dropFirst())
            : cookie.domain).lowercased()
          if host == cookieDomain || host.hasSuffix("." + cookieDomain) {
            storage.deleteCookie(cookie)
          }
        }
      }

      group.notify(queue: .main) {
        CookieStoreObserverHandler.shared.endInternalWrite()
        result(deletedCount)
      }
    }
  }

  /// 精确删除指定 (name, domain, path) 的单条 cookie 变体
  private static func deleteExactCookieIOS(
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

      CookieStoreObserverHandler.shared.beginInternalWrite()
      let group = DispatchGroup()
      group.enter()
      store.delete(cookie) {
        group.leave()
      }

      // 双删: 同步清 HTTPCookieStorage.shared 中匹配的同名 cookie
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
        CookieStoreObserverHandler.shared.endInternalWrite()
        result(true)
      }
    }
  }

  /// 读取指定 url 下所有适用 cookie 的完整信息
  ///
  /// 适用判断: cookie.domain (去前导点) == host, 或 host 是其子域
  private static func getAllCookieInfosIOS(url: URL, result: @escaping FlutterResult) {
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
          "sameSite": AppDelegate.sameSiteString(cookie),
        ]
      }

      DispatchQueue.main.async {
        result(infos)
      }
    }
  }

  /// 统计指定 url 下 cookie name 的变体数 (适用域过滤)
  private static func countCookiesByNameIOS(url: URL, name: String, result: @escaping FlutterResult) {
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

  /// 启动临时 HTTP server 提供 mobileconfig 下载，使用 SFSafariViewController 在应用内打开
  /// 应用保持前台运行，避免后台被系统回收导致下载失败
  private func serveMobileconfigViaSafari(_ mobileconfig: String, completion: @escaping (Bool) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      // 创建 TCP socket
      let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
      guard serverSocket >= 0 else {
        DispatchQueue.main.async { completion(false) }
        return
      }

      var reuse: Int32 = 1
      setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

      // 设置 accept 超时 30 秒，防止永久阻塞
      var timeout = timeval(tv_sec: 30, tv_usec: 0)
      setsockopt(serverSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

      var addr = sockaddr_in()
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = 0
      addr.sin_addr.s_addr = inet_addr("127.0.0.1")
      addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

      let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard bindResult == 0 else {
        close(serverSocket)
        DispatchQueue.main.async { completion(false) }
        return
      }

      listen(serverSocket, 5)

      var boundAddr = sockaddr_in()
      var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      withUnsafeMutablePointer(to: &boundAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getsockname(serverSocket, $0, &addrLen)
        }
      }
      let port = Int(CFSwapInt16BigToHost(boundAddr.sin_port))

      // 使用 SFSafariViewController 在应用内打开，保持前台运行
      let url = URL(string: "http://127.0.0.1:\(port)/ca.mobileconfig")!
      DispatchQueue.main.async {
        guard let rootVC = self.window?.rootViewController else {
          completion(false)
          return
        }
        let safariVC = SFSafariViewController(url: url)
        safariVC.modalPresentationStyle = .pageSheet
        rootVC.present(safariVC, animated: true)
        completion(true)
      }

      // 循环处理连接：Safari 可能发送 favicon 等额外请求
      let body = Data(mobileconfig.utf8)
      var served = false
      for _ in 0..<10 {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { break } // 超时或错误

        // 读取请求
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)

        // 解析请求路径
        var isMobileconfig = false
        if bytesRead > 0,
           let request = String(bytes: buffer[..<bytesRead], encoding: .utf8),
           let firstLine = request.split(separator: "\r\n").first {
          isMobileconfig = firstLine.contains("/ca.mobileconfig")
        }

        if isMobileconfig {
          // 返回描述文件
          let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/x-apple-aspen-config\r\n" +
            "Content-Disposition: attachment; filename=\"DOH_Proxy_CA.mobileconfig\"\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
          _ = send(clientSocket, header, header.utf8.count, 0)
          body.withUnsafeBytes { ptr in
            _ = send(clientSocket, ptr.baseAddress, body.count, 0)
          }
          close(clientSocket)
          served = true
          break
        } else {
          // 非目标请求，返回 404
          let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          _ = send(clientSocket, notFound, notFound.utf8.count, 0)
          close(clientSocket)
        }
      }

      close(serverSocket)

      // 如果超时未提供文件，关闭 SFSafariViewController
      if !served {
        DispatchQueue.main.async {
          self.window?.rootViewController?.presentedViewController?.dismiss(animated: true)
        }
      }
    }
  }
}

// MARK: - Cookie Store Observer (v0.4.0 Phase B)
//
// 与 macOS MainFlutterWindow.swift 中同名类实现对称。
// 注册 WKHTTPCookieStoreObserver 监听 WV 网络层 cookie 变化,
// 通过 channel `com.fluxdo/cookie_observer` 通知 Dart sweep。
//
// 防重入: 我们自己 setCookie/nukeAllVariants/deleteExactCookie 时,
// internalWriteCount > 0, observer 看到事件就忽略,
// 避免 setCookie → cookiesDidChange → sweep → setCookie 死循环。
class CookieStoreObserverHandler: NSObject, WKHTTPCookieStoreObserver {
  static let shared = CookieStoreObserverHandler()

  private var channel: FlutterMethodChannel?
  private let lock = NSLock()
  private var internalWriteCount = 0
  private var attached = false

  func attach(channel: FlutterMethodChannel) {
    self.channel = channel
    if attached { return }
    attached = true
    DispatchQueue.main.async {
      let store = WKWebsiteDataStore.default().httpCookieStore
      store.add(self)
    }
  }

  func beginInternalWrite() {
    lock.lock()
    internalWriteCount += 1
    lock.unlock()
  }

  func endInternalWrite() {
    lock.lock()
    internalWriteCount = max(0, internalWriteCount - 1)
    lock.unlock()
  }

  // WKHTTPCookieStoreObserver
  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    lock.lock()
    let isInternal = internalWriteCount > 0
    lock.unlock()
    if isInternal { return }

    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onCookiesChanged", arguments: nil)
    }
  }
}
