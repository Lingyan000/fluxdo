// 原生 WKWebView 回环采样宿主；只用于诊断，不包含业务登录或 CSRF 流程。
import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class Probe: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: WKWebViewConfiguration())
    var observation: NSKeyValueObservation?
    var finished = false
    var target: URL?
    var nativeUA = ""

    func start() {
        guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix("https://localhost:") }),
              let url = URL(string: raw), url.host == "localhost", url.path == "/fluxdo-probe" else {
            complete(error: "只允许本地指纹探针地址")
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
            if ProcessInfo.processInfo.environment["FLUXDO_APPLE_UA_MODE"] == "app" {
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
        return ua.replacingOccurrences(of: "Mobile/", with: "Version/\(version) Mobile/") + " Safari/604.1"
        #endif
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        // 与应用探针一样，只接受指定回环端口的服务端证书挑战。
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "localhost", space.port == target?.port,
           let trust = space.serverTrust {
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
        #else
        let platform = "ios-simulator-wkwebview"
        #endif
        let result: [String: Any] = ["engine": "native WKWebView", "platform": platform,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "native_user_agent": nativeUA, "custom_user_agent": webView.customUserAgent ?? "",
            "success": error == nil, "error": error ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
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
        controller.view = probe.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        probe.start()
        return true
    }
}
#endif

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
