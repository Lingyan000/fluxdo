// iOS 宿主调用生产 C ABI；只访问显式指定的诊断源站。
import Foundation
import CFNetwork
import UIKit
import WebKit

typealias CoreEvent = @convention(c) (UInt64, UInt8, UnsafeMutablePointer<UInt8>?, Int) -> Void
typealias CoreLog = @convention(c) (UInt8, UnsafeMutablePointer<UInt8>?, Int) -> Void
@_silgen_name("fluxdo_net_init_logging") func coreInitLogging()
@_silgen_name("fluxdo_net_set_log_callback") func coreSetLogCallback(_ callback: CoreLog?)
@_silgen_name("fluxdo_net_init") func coreInit(_ config: UnsafePointer<CChar>) -> Int32
@_silgen_name("fluxdo_net_status_json") func coreStatus() -> UnsafeMutablePointer<CChar>?
@_silgen_name("fluxdo_net_diagnostic_h3_profile_json") func coreProfile() -> UnsafeMutablePointer<CChar>?
@_silgen_name("fluxdo_net_free_string") func coreFreeString(_ value: UnsafeMutablePointer<CChar>?)
@_silgen_name("fluxdo_net_set_event_callback") func coreSetCallback(_ callback: CoreEvent?)
@_silgen_name("fluxdo_net_request_start") func coreRequest(_ meta: UnsafePointer<CChar>) -> UInt64
@_silgen_name("fluxdo_net_request_write") func coreWrite(_ id: UInt64, _ bytes: UnsafePointer<UInt8>?, _ size: Int) -> Int32
@_silgen_name("fluxdo_net_request_finish") func coreFinish(_ id: UInt64)
@_silgen_name("fluxdo_net_request_cancel") func coreCancel(_ id: UInt64)
@_silgen_name("fluxdo_net_buffer_free") func coreFree(_ bytes: UnsafeMutablePointer<UInt8>?, _ size: Int)
@_silgen_name("fluxdo_net_detach_host") func coreDetach()

enum CoreProbeError: Error { case failed(String) }

// 核心线程只复制并归还缓冲；所有请求状态都在主线程更新。
private func receiveCoreEvent(_ id: UInt64, _ kind: UInt8, _ bytes: UnsafeMutablePointer<UInt8>?, _ size: Int) {
    let data = bytes.map { Data(bytes: $0, count: size) } ?? Data()
    if let bytes = bytes { coreFree(bytes, size) }
    DispatchQueue.main.async { CoreProbe.active?.receive(id, kind, data) }
}

private func receiveCoreLog(_ level: UInt8, _ bytes: UnsafeMutablePointer<UInt8>?, _ size: Int) {
    let data = bytes.map { Data(bytes: $0, count: size) } ?? Data()
    if let bytes = bytes { coreFree(bytes, size) }
    guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = row["message"] as? String, message.contains("HTTP/3 upgrade") else { return }
    // 只保留固定分类；不导出代理地址、目标域名、查询串或原始错误正文。
    let reason = message.contains("configured proxy uses TCP") ? "proxy_requires_tcp" :
        message.contains("H3 connect timeout") ? "connect_timeout" :
        message.contains("ready in") ? "upgrade_ready" : "upgrade_unavailable"
    DispatchQueue.main.async {
        guard let active = CoreProbe.active, active.protocolEvents.count < 16 else { return }
        active.protocolEvents.append(reason)
    }
}

@MainActor
final class CoreProbe: NSObject, WKNavigationDelegate {
    static var active: CoreProbe?
    let controller: UIViewController
    var probe: Probe?
    var userAgent = ""
    var finished = false
    var traceURL: URL?
    var traceView: WKWebView?
    var navigation: CheckedContinuation<Void, Error>?
    var navigationGeneration = 0
    var navigationHeaders: [String: String] = [:]
    var report: [String: Any] = ["engine": "iOS production Core FFI", "core_running_on_ios": true,
        "physical_device": false, "full_flutter_app": false, "success": false]
    var requests: [[String: Any]] = []
    var calibrations: [[String: Any]] = []
    var protocolEvents: [String] = []
    struct Pending {
        var head: [String: Any] = [:]
        var bytes = Data()
        let continuation: CheckedContinuation<[String: Any], Error>
    }
    var pending: [UInt64: Pending] = [:]

    init(_ controller: UIViewController) { self.controller = controller; super.init() }

    func finishNavigation(_ error: Error? = nil) {
        guard let pending = navigation else { return }
        navigation = nil
        if let error = error { pending.resume(throwing: error) } else { pending.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishNavigation() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishNavigation(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishNavigation(error) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == traceURL ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
            navigationHeaders = [:]
            for (key, value) in http.allHeaderFields {
                let name = String(describing: key).lowercased()
                if name == "alt-svc" || name == "server" { navigationHeaders[name] = String(describing: value) }
            }
        }
        decisionHandler(.allow)
    }

    func responseHeader(_ response: [String: Any], _ name: String) -> String {
        let headers = response["headers"] as? [[String]] ?? []
        return headers.first { $0.count == 2 && $0[0].lowercased() == name }?[1] ?? ""
    }

    func traceFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        // 公开诊断响应也可能含出口 IP；证据只保留协议与 TLS 状态。
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && ["http", "tls", "sni"].contains(String(parts[0])) {
                result[String(parts[0])] = String(parts[1])
            }
        }
        return result
    }

    func publicTrace(_ url: URL) async throws {
        traceURL = url
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() {
            let choices = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as NSArray
            let types = choices.compactMap { ($0 as? NSDictionary)?[kCFProxyTypeKey] as? String }
            report["public_proxy_route"] = ["types": types,
                "requires_pac_evaluation": types.contains(kCFProxyTypeAutoConfigurationURL as String) ||
                    types.contains(kCFProxyTypeAutoConfigurationJavaScript as String)]
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
        traceView = webView
        controller.view = webView
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.query = nil
        let primer = components.url!
        var native: [[String: String]] = []
        for attempt in 0..<4 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigation = continuation
                navigationGeneration += 1
                let generation = navigationGeneration
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
                // 公网首次 DNS/TLS 建连单独有界，后续导航仍用较短预算。
                DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 20 : 8)) { [weak self, weak webView] in
                    // 只取消仍在等待的导航；前一轮已完成的定时器不能影响下一轮。
                    guard let self = self, self.navigationGeneration == generation, self.navigation != nil else { return }
                    self.finishNavigation(CoreProbeError.failed("Public trace navigation timed out"))
                    webView?.stopLoading()
                }
            }
            let body = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
            var fields = traceFields(body)
            fields["alt_svc"] = navigationHeaders["alt-svc"] ?? ""
            fields["server"] = navigationHeaders["server"] ?? ""
            native.append(fields)
            report["native_public_trace"] = native
            if ["h3", "http/3"].contains(fields["http"]?.lowercased() ?? "") { break }
            if attempt == 0 {
                // trace 页不发送 Alt-Svc；只 fetch 同源首页取得协议声明，不导航、执行或提交其内容。
                let result = try await webView.callAsyncJavaScript("""
                    const controller = new AbortController();
                    const timer = setTimeout(() => controller.abort(), 8000);
                    try {
                        const response = await fetch(url, {credentials: 'omit', cache: 'no-store',
                            redirect: 'error', signal: controller.signal});
                        const result = {status: response.status, alt_svc: response.headers.get('alt-svc') || '',
                            server: response.headers.get('server') || ''};
                        await response.text();
                        return result;
                    } finally { clearTimeout(timer); }
                    """, arguments: ["url": primer.absoluteString], in: nil, contentWorld: .page)
                let advertisement = result as? [String: Any] ?? [:]
                report["native_public_prime"] = advertisement
                guard (advertisement["alt_svc"] as? String ?? "").lowercased().contains("h3=") else {
                    throw CoreProbeError.failed("Public origin did not advertise H3 to WebView")
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        report["native_public_trace"] = native
        let advertised = try await request(primer.absoluteString)
        report["core_public_prime"] = ["status": advertised["status"] ?? 0,
            "alt_svc": responseHeader(advertised, "alt-svc"), "server": responseHeader(advertised, "server")]
        guard responseHeader(advertised, "alt-svc").lowercased().contains("h3=") else {
            throw CoreProbeError.failed("Public origin did not advertise H3 to Core")
        }
        var core: [[String: Any]] = []
        for _ in 0..<12 {
            let response = try await request(url.absoluteString)
            let fields = traceFields(response["body"] as? String ?? "")
            core.append(["http_version": response["http_version"] ?? "", "status": response["status"] ?? 0,
                "alt_svc": responseHeader(response, "alt-svc"), "server": responseHeader(response, "server"), "trace": fields])
            if response["http_version"] as? String == "3.0", ["h3", "http/3"].contains(fields["http"]?.lowercased() ?? "") { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        report["core_public_trace"] = core
        report["public_final_state"] = try state()
        report["scope"] = "Public protocol confirmation with live in-app calibration and same-origin Alt-Svc discovery; no server-side wire fingerprint comparison"
        guard native.contains(where: { ["h3", "http/3"].contains($0["http"]?.lowercased() ?? "") }),
              core.last?["http_version"] as? String == "3.0" else {
            throw CoreProbeError.failed("Native and Core did not both confirm public H3")
        }
    }

    func state() throws -> [String: Any] {
        guard let text = coreStatus() else { throw CoreProbeError.failed("Core status missing") }
        defer { coreFreeString(text) }
        return try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as! [String: Any]
    }

    func navigate(_ url: String) async throws {
        let result: [String: Any] = await withCheckedContinuation { continuation in
            let child = Probe()
            child.initialURL = url
            child.userAgentOverride = userAgent
            child.completion = { continuation.resume(returning: $0) }
            probe = child
            controller.view = child.webView
            child.start()
        }
        calibrations.append(result)
        probe = nil
        guard result["success"] as? Bool == true else {
            throw CoreProbeError.failed("Native calibration failed: \(result["error"] ?? "missing result")")
        }
    }

    func receive(_ id: UInt64, _ kind: UInt8, _ data: Data) {
        guard var item = pending[id] else { return }
        switch kind {
        case 0:
            guard let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                pending.removeValue(forKey: id)
                coreCancel(id)
                item.continuation.resume(throwing: CoreProbeError.failed("Invalid Core response head"))
                return
            }
            item.head = head
            pending[id] = item
        case 1:
            if item.bytes.count + data.count > 131072 {
                pending.removeValue(forKey: id)
                coreCancel(id)
                item.continuation.resume(throwing: CoreProbeError.failed("Synthetic response exceeded budget"))
                return
            }
            item.bytes.append(data)
            pending[id] = item
        case 2, 3:
            pending.removeValue(forKey: id)
            if kind == 3 {
                item.continuation.resume(throwing: CoreProbeError.failed(String(data: data, encoding: .utf8) ?? "Core error"))
            } else {
                item.head["body"] = String(data: item.bytes, encoding: .utf8) ?? ""
                item.continuation.resume(returning: item.head)
            }
        default: break
        }
    }

    func request(_ url: String, method: String = "GET", headers: [[String]] = [], body: String = "") async throws -> [String: Any] {
        let length = body.isEmpty ? [] : [["content-length", String(body.utf8.count)]]
        let meta: [String: Any] = ["method": method, "url": url,
            "headers": [["user-agent", userAgent], ["accept", "*/*"]] + headers + length,
            "has_body": !body.isEmpty, "connect_timeout_ms": 5000,
            "send_timeout_ms": 5000, "receive_timeout_ms": 5000]
        let json = String(data: try JSONSerialization.data(withJSONObject: meta), encoding: .utf8)!
        return try await withCheckedThrowingContinuation { continuation in
            let id = json.withCString { coreRequest($0) }
            guard id != 0 else {
                continuation.resume(throwing: CoreProbeError.failed("Core rejected request metadata"))
                return
            }
            pending[id] = Pending(continuation: continuation)
            if !body.isEmpty {
                let payload = Array(body.utf8)
                let code = payload.withUnsafeBufferPointer { coreWrite(id, $0.baseAddress, $0.count) }
                guard code == 0 else {
                    pending.removeValue(forKey: id)
                    coreCancel(id)
                    continuation.resume(throwing: CoreProbeError.failed("Core upload write failed: \(code)"))
                    return
                }
                coreFinish(id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let item = self?.pending.removeValue(forKey: id) else { return }
                coreCancel(id)
                item.continuation.resume(throwing: CoreProbeError.failed("Core request timed out"))
            }
        }
    }

    func run() async {
        CoreProbe.active = self
        coreSetLogCallback(receiveCoreLog)
        coreInitLogging()
        coreSetCallback(receiveCoreEvent)
        do {
            let traceConfig = Bundle.main.url(forResource: "trace-target", withExtension: "json")
            let trace = try traceConfig.map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: String] }
            guard let raw = trace?["url"] ?? CommandLine.arguments.first(where: { $0.hasPrefix("https://") }),
                  let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
                  let host = url.host else {
                throw CoreProbeError.failed("Explicit trusted synthetic origin required")
            }
            let port = url.port ?? 443
            if trace == nil {
                guard host == ProcessInfo.processInfo.environment["FLUXDO_TRUSTED_PROBE_HOST"],
                      host.range(of: "^[a-z0-9][a-z0-9-]*\\.[a-z0-9-]+\\.ts\\.net$", options: .regularExpression) != nil,
                      url.port != nil, url.path == "/fluxdo-probe" else {
                    throw CoreProbeError.failed("Explicit trusted synthetic origin required")
                }
            } else { traceURL = url }
            #if targetEnvironment(simulator)
            report["physical_device"] = false
            #else
            report["physical_device"] = true
            #endif
            let identity = Probe()
            controller.view = identity.webView
            let native = try await identity.webView.evaluateJavaScript("navigator.userAgent") as! String
            userAgent = identity.appUA(native)
            report["native_user_agent"] = native
            report["custom_user_agent"] = userAgent
            report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
            report["browser_identity"] = BrowserIdentity.diagnostics()
            let config: [String: Any] = ["bind_addr": "127.0.0.1", "bind_port": 0,
                "fingerprint_platform": "ios", "fingerprint_user_agent": userAgent,
                "fingerprint_runtime_identity": ProcessInfo.processInfo.operatingSystemVersionString,
                "enable_doh": false, "webview_mitm": false, "timeout_secs": 5]
            let configText = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
            let localPort = configText.withCString { coreInit($0) }
            guard localPort > 0 else { throw CoreProbeError.failed("Core initialization failed") }
            report["stage"] = "tcp_calibration"
            for attempt in 0..<2 {
                try await navigate("https://localhost:\(localPort)/fluxdo-probe")
                // 与正式 Dart 宿主一致：服务端在 done 后 100 ms 关闭连接，
                // 第二轮等待 150 ms，避免 iPad 全局连接池复用第一次 TLS。
                if attempt == 0 { try await Task.sleep(nanoseconds: 150_000_000) }
            }
            let tcp = try state()
            report["tcp_state"] = tcp
            guard tcp["template_ready"] as? Bool == true,
                  tcp["user_agent"] as? String == userAgent,
                  let diagnostics = tcp["template_diagnostics"] as? [String: Any],
                  let h3 = diagnostics["h3"] as? [String: Any],
                  let ports = h3["probe_ports"] as? [Int], ports.count == 2 else {
                throw CoreProbeError.failed("Live iOS TCP calibration incomplete")
            }
            report["stage"] = "h3_calibration"
            for probePort in ports { try await navigate("https://localhost:\(probePort)/fluxdo-h3") }
            let calibrated = try state()
            report["calibrated_state"] = calibrated
            guard let diagnostics = calibrated["template_diagnostics"] as? [String: Any],
                  let h3 = diagnostics["h3"] as? [String: Any], h3["enabled_for_template"] as? Bool == true else {
                throw CoreProbeError.failed("Live iOS H3 calibration incomplete")
            }
            if trace != nil {
                report["stage"] = "public_protocol"
                try await publicTrace(url)
                report["success"] = true
                finish()
                return
            }
            report["stage"] = "controlled_replay"
            guard let profileText = coreProfile() else { throw CoreProbeError.failed("Calibrated profile missing") }
            defer { coreFreeString(profileText) }
            let profile = try JSONSerialization.jsonObject(with: Data(String(cString: profileText).utf8))
            guard profile is [String: Any] else { throw CoreProbeError.failed("Calibrated profile unavailable") }
            report["calibrated_profile"] = profile
            let origin = "https://\(host):\(port)"
            var reached = false
            for _ in 0..<15 {
                let row = try await request(origin + "/fluxdo-probe/fetch")
                requests.append(row)
                if row["http_version"] as? String == "3.0" { reached = true; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard reached else { throw CoreProbeError.failed("iOS Core did not reach H3") }
            let cases: [(String, String, [[String]], String)] = [
                ("warm-0", "GET", [], ""), ("warm-1", "GET", [], ""),
                ("conditional", "GET", [["if-none-match", "\"fluxdo-lab-etag\""]], ""),
                ("form", "POST", [["content-type", "application/x-www-form-urlencoded"]], "sample=one&value=two"),
                ("json", "POST", [["content-type", "application/json"]], "{\"sample\":1}"),
                ("range", "GET", [["range", "bytes=0-15"]], ""), ("head", "HEAD", [], ""),
                ("conditional-changed", "GET", [["if-none-match", "\"fluxdo-lab-etag-changed-20261115\""]], ""),
                ("form-again", "POST", [["content-type", "application/x-www-form-urlencoded"]], "sample=two&value=one"),
                ("conditional-again", "GET", [["if-none-match", "\"fluxdo-lab-etag\""]], ""),
                ("conditional-third", "GET", [["if-none-match", "\"fluxdo-lab-etag\""]], "")]
            for (name, method, headers, body) in cases {
                var row = try await request(origin + "/fluxdo-probe/qpack/" + name, method: method, headers: headers, body: body)
                row["case"] = name
                requests.append(row)
                guard row["http_version"] as? String == "3.0" else { throw CoreProbeError.failed("QPACK case fell back to TCP") }
            }
            for name in ["done", "finished"] { requests.append(try await request(origin + "/fluxdo-probe/" + name)) }
            report["success"] = true
        } catch { report["error"] = String(describing: error) }
        finish()
    }

    func finish() {
        if finished { return }
        finished = true
        report["requests"] = requests
        report["calibration_browsers"] = calibrations
        coreSetLogCallback(nil)
        report["protocol_events"] = protocolEvents
        coreDetach()
        CoreProbe.active = nil
        report["core_shutdown"] = (try? state()["running"] as? Bool) == false
        if report["core_shutdown"] as? Bool != true { report["success"] = false }
        if traceURL != nil {
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { exit(1) }
            if let name = ProcessInfo.processInfo.environment["FLUXDO_APPLE_REPORT_FILE"],
               name.hasPrefix("fluxdo-report-"), !name.contains("/") {
                do { try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name), options: .atomic) }
                catch { exit(1) }
            }
            let text = UITextView(frame: controller.view.bounds)
            text.isEditable = false
            text.accessibilityIdentifier = "fluxdo-core-report"
            text.text = String(data: data, encoding: .utf8)!
            controller.view = text
            return
        }
        guard let name = ProcessInfo.processInfo.environment["FLUXDO_APPLE_REPORT_FILE"],
              name.hasPrefix("fluxdo-report-"), !name.contains("/"),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name), options: .atomic) }
        catch { exit(1) }
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
        exit(report["success"] as? Bool == true ? 0 : 1)
    }
}

@MainActor
final class CoreHost: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var runner: CoreProbe?
    var warmup: Probe?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { [self] in
            if CommandLine.arguments.contains("--warmup") {
                let probe = Probe(); warmup = probe
                controller.view = probe.webView; probe.start()
            } else {
                let probe = CoreProbe(controller); runner = probe
                DispatchQueue.main.asyncAfter(deadline: .now() + 160) { [weak probe] in
                    probe?.report["error"] = "iOS Core diagnostic exceeded time budget"
                    probe?.finish()
                }
                Task { await probe.run() }
            }
        }
        return true
    }
}

@main
struct CoreEntry {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(CoreHost.self))
    }
}
