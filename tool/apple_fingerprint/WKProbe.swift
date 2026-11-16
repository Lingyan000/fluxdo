// 原生 WKWebView 回环采样宿主；只用于诊断，不包含业务登录或 CSRF 流程。
import Foundation
import WebKit
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class Probe: NSObject, WKNavigationDelegate {
    lazy var webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: WKWebViewConfiguration())
    var observation: NSKeyValueObservation?
    var finished = false
    var target: URL?
    var nativeUA = ""
    var trustedCertificateRequired = false
    var trustEvaluations: [[String: Any]] = []
    var certificateErrors = 0
    var credentialsUsed = 0
    // 同进程 Core 诊断可复用导航逻辑；常规命令行宿主仍在报告后退出。
    var initialURL: String?
    // 应用内宿主直接传入实际 UA，不依赖模拟器专用环境变量。
    var userAgentOverride: String?
    var completion: (([String: Any]) -> Void)?

    func start() {
        if CommandLine.arguments.contains("--warmup") {
            // 单独记录 WebContent 冷启动，避免把模拟器首次启动耗时算作网络探针结果。
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.complete(error: "WKWebView 初始化超时")
            }
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, error in
                guard let self = self, let ua = value as? String else {
                    self?.complete(error: "WebContent 初始化失败: \(String(describing: error))")
                    return
                }
                self.nativeUA = ua
                self.complete(error: nil)
            }
            return
        }
        guard let raw = initialURL ?? CommandLine.arguments.first(where: { $0.hasPrefix("https://") }),
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              let hostname = url.host, url.port != nil, (url.path == "/fluxdo-probe" || url.path == "/fluxdo-h3") else {
            complete(error: "指纹探针地址无效")
            return
        }
        let trustedHost = ProcessInfo.processInfo.environment["FLUXDO_TRUSTED_PROBE_HOST"] ?? ""
        trustedCertificateRequired = trustedHost == hostname &&
            trustedHost.range(of: "^[a-z0-9][a-z0-9-]*\\.[a-z0-9-]+\\.ts\\.net$", options: .regularExpression) != nil
        guard hostname == "localhost" || trustedCertificateRequired else {
            complete(error: "只允许本地或显式指定的可信探针地址")
            return
        }
        target = url
        webView.navigationDelegate = self
        observation = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            if view.title == "fluxdo-probe-done" {
                DispatchQueue.main.async { self?.complete(error: nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.complete(error: "WKWebView 探针超时")
        }
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, error in
            guard let self = self, let ua = value as? String else {
                self?.complete(error: "无法读取原生 UA: \(String(describing: error))")
                return
            }
            self.nativeUA = ua
            if let override = self.userAgentOverride {
                self.webView.customUserAgent = override
            } else if ProcessInfo.processInfo.environment["FLUXDO_APPLE_UA_MODE"] == "app" {
                self.webView.customUserAgent = self.appUA(ua)
            }
            self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    // 与 lib/constants.dart 的 Apple UA 规则对应；保留原始 UA 供比对。
    func appUA(_ ua: String) -> String {
        if ua.contains("Safari/") { return ua }
        #if os(macOS)
        let candidates = ["/Applications/Safari.app", "/System/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        let version = candidates.compactMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }.first ?? "18.5"
        let webkit = ua.components(separatedBy: "AppleWebKit/").last?.components(separatedBy: " ").first ?? "605.1.15"
        return ua + " Version/\(version) Safari/\(webkit)"
        #else
        let regex = try! NSRegularExpression(pattern: "CPU (?:iPhone )?OS (\\d+)[_\\.](\\d+)")
        let text = ua as NSString
        var version = "18.0"
        if let match = regex.firstMatch(in: ua, range: NSRange(location: 0, length: text.length)) {
            version = text.substring(with: match.range(at: 1)) + "." + text.substring(with: match.range(at: 2))
        }
        if let actual = BrowserIdentity.safariVersion(),
           actual.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil {
            version = actual
        }
        return ua.replacingOccurrences(of: "Mobile/", with: "Version/\(version) Mobile/") + " Safari/604.1"
        #endif
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 可信入口只观察系统验证结果，始终交回系统处理，不安装根证书或放行错误。
        if trustedCertificateRequired {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = space.serverTrust {
                var failure: CFError?
                let valid = SecTrustEvaluateWithError(trust, &failure)
                trustEvaluations.append(["hostname": space.host, "port": space.port,
                    "system_trusted": valid, "error": failure.map { String(describing: $0) } ?? ""])
                if !valid { certificateErrors += 1 }
            }
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 系统信任实验不使用证书回调放行，确保 OS 真正验证实验 CA 与主机名。
        if ProcessInfo.processInfo.environment["FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST"] == "1" {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        // 与应用探针一样，只接受指定回环端口的服务端证书挑战。
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "localhost", space.port == target?.port,
           let trust = space.serverTrust {
            credentialsUsed += 1
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(error: error.localizedDescription)
    }

    func complete(error: String?) {
        if finished { return }
        finished = true
        #if os(macOS)
        let platform = "macos-wkwebview"
        #elseif targetEnvironment(simulator)
        let platform = "ios-simulator-wkwebview"
        #else
        let platform = "ios-device-wkwebview"
        #endif
        let result: [String: Any] = ["engine": "native WKWebView", "platform": platform,
            "warmup": CommandLine.arguments.contains("--warmup"),
            "trusted_certificate_required": trustedCertificateRequired,
            "system_trust_evaluations": trustEvaluations,
            "ssl_error_count": certificateErrors, "ssl_errors_proceeded": credentialsUsed,
            "certificate_rejected": certificateErrors > 0,
            "diagnostic_force_quic": false, "udp_relay": false,
            "requires_system_trust": ProcessInfo.processInfo.environment["FLUXDO_APPLE_REQUIRE_SYSTEM_TRUST"] == "1",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "native_user_agent": nativeUA, "custom_user_agent": webView.customUserAgent ?? "",
            // 只核验公开 Bundle 元数据是否可读，不使用私有 WebKit API。
            "safari_bundle_version": BrowserIdentity.safariVersion() ?? "",
            "webkit_bundle_version": Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "success": error == nil, "error": error ?? ""]
        if let completion = completion {
            observation = nil
            webView.stopLoading()
            completion(result)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            // simctl 的控制台转发可能在应用退出时丢失最后一行；每次启动使用独立结果文件。
            if let name = ProcessInfo.processInfo.environment["FLUXDO_APPLE_REPORT_FILE"],
               name.hasPrefix("fluxdo-report-"), !name.contains("/") {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
                do { try data.write(to: url, options: .atomic) }
                catch { fputs("无法保存原生诊断结果: \(error)\n", stderr); exit(1) }
            }
            print(text)
            fflush(stdout)
        }
        exit(error == nil ? 0 : 1)
    }
}

#if os(macOS)
@MainActor
final class Host: NSObject, NSApplicationDelegate {
    let probe = Probe()
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: probe.webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = probe.webView
        window.orderFrontRegardless()
        self.window = window
        probe.start()
    }
}
#else
@MainActor
final class Host: UIResponder, UIApplicationDelegate {
    let probe = Probe()
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        // 先完成 UIKit 启动，再创建 WebView，避免在应用启动回调前等待 WebKit 服务。
        DispatchQueue.main.async { [self] in
            controller.view = probe.webView
            probe.start()
        }
        return true
    }
}
#endif

#if !FLUXDO_CORE_DIAGNOSTIC
@main
struct Entry {
    @MainActor static func main() {
        #if os(macOS)
        let app = NSApplication.shared
        let host = Host()
        app.delegate = host
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(host) { app.run() }
        #else
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Host.self))
        #endif
    }
}
#endif
