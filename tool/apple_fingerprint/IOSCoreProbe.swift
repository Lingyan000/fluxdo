// iOS 模拟器内调用生产 C ABI；只访问显式指定的合成诊断源站。
import Foundation
import UIKit
import WebKit

typealias CoreEvent = @convention(c) (UInt64, UInt8, UnsafeMutablePointer<UInt8>?, Int) -> Void
@_silgen_name("fluxdo_net_init") func coreInit(_ config: UnsafePointer<CChar>) -> Int32
@_silgen_name("fluxdo_net_status_json") func coreStatus() -> UnsafeMutablePointer<CChar>?
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

@MainActor
final class CoreProbe {
    static var active: CoreProbe?
    let controller: UIViewController
    var probe: Probe?
    var userAgent = ""
    var finished = false
    var report: [String: Any] = ["engine": "iOS production Core FFI", "core_running_on_ios": true,
        "physical_device": false, "full_flutter_app": false, "success": false]
    var requests: [[String: Any]] = []
    var calibrations: [[String: Any]] = []
    struct Pending {
        var head: [String: Any] = [:]
        var bytes = Data()
        let continuation: CheckedContinuation<[String: Any], Error>
    }
    var pending: [UInt64: Pending] = [:]

    init(_ controller: UIViewController) { self.controller = controller }

    func state() throws -> [String: Any] {
        guard let text = coreStatus() else { throw CoreProbeError.failed("Core status missing") }
        defer { coreFreeString(text) }
        return try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as! [String: Any]
    }

    func navigate(_ url: String) async throws {
        let result: [String: Any] = await withCheckedContinuation { continuation in
            let child = Probe()
            child.initialURL = url
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
        coreSetCallback(receiveCoreEvent)
        do {
            guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix("https://") }),
                  let url = URL(string: raw), url.user == nil, url.password == nil,
                  let host = url.host, let port = url.port,
                  host == ProcessInfo.processInfo.environment["FLUXDO_TRUSTED_PROBE_HOST"],
                  host.range(of: "^[a-z0-9][a-z0-9-]*\\.[a-z0-9-]+\\.ts\\.net$", options: .regularExpression) != nil,
                  url.path == "/fluxdo-probe" else {
                throw CoreProbeError.failed("Explicit trusted synthetic origin required")
            }
            let identity = Probe()
            controller.view = identity.webView
            let native = try await identity.webView.evaluateJavaScript("navigator.userAgent") as! String
            userAgent = identity.appUA(native)
            report["native_user_agent"] = native
            report["custom_user_agent"] = userAgent
            report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
            let config: [String: Any] = ["bind_addr": "127.0.0.1", "bind_port": 0,
                "fingerprint_platform": "ios", "fingerprint_user_agent": userAgent,
                "fingerprint_runtime_identity": ProcessInfo.processInfo.operatingSystemVersionString,
                "enable_doh": false, "webview_mitm": false, "timeout_secs": 5]
            let configText = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
            let localPort = configText.withCString { coreInit($0) }
            guard localPort > 0 else { throw CoreProbeError.failed("Core initialization failed") }
            for _ in 0..<2 { try await navigate("https://localhost:\(localPort)/fluxdo-probe") }
            let tcp = try state()
            report["tcp_state"] = tcp
            guard tcp["template_ready"] as? Bool == true,
                  let diagnostics = tcp["template_diagnostics"] as? [String: Any],
                  let h3 = diagnostics["h3"] as? [String: Any],
                  let ports = h3["probe_ports"] as? [Int], ports.count == 2 else {
                throw CoreProbeError.failed("Live iOS TCP calibration incomplete")
            }
            for probePort in ports { try await navigate("https://localhost:\(probePort)/fluxdo-h3") }
            let calibrated = try state()
            report["calibrated_state"] = calibrated
            guard let diagnostics = calibrated["template_diagnostics"] as? [String: Any],
                  let h3 = diagnostics["h3"] as? [String: Any], h3["enabled_for_template"] as? Bool == true else {
                throw CoreProbeError.failed("Live iOS H3 calibration incomplete")
            }
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
        coreDetach()
        report["core_shutdown"] = (try? state()["running"] as? Bool) == false
        if report["core_shutdown"] as? Bool != true { report["success"] = false }
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
