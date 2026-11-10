// Standalone Cocoa regression. No user data store, real site, or Flutter build.
import AppKit
import WebKit

final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var window: NSWindow!
    var index = 0
    var finished = false
    let modes = ["loadData", "loadSimulatedRequest", "loadRequest"]
    let entry = URL(string: "https://localhost:8765/apps/01a1b02d-04ed-7342-baa5-769b244b7b9a?embed_mode=true&room=42#invite")!

    func record(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
    }
    func start() {
        finished = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "probe")
        let compat = try! String(contentsOfFile: "assets/polyfill/compat-polyfill.js", encoding: .utf8)
        configuration.userContentController.addUserScript(WKUserScript(source: "window.__fluxdoErudaInited=true;" + compat, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => window.webkit.messageHandlers.probe.postMessage({error:String(e.message)}));
          window.addEventListener('unhandledrejection', e => window.webkit.messageHandlers.probe.postMessage({rejection:String(e.reason)}));
          """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        let cookie = HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "probe_session", .value: "synthetic", .secure: "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax])!
        configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            let html = try! Data(contentsOf: URL(fileURLWithPath: "build/mac-probe/host.html"))
            self.record(["mode": self.modes[self.index], "event": "start", "os": ProcessInfo.processInfo.operatingSystemVersionString])
            switch self.index {
            case 0: self.webView.load(html, mimeType: "text/html", characterEncodingName: "utf8", baseURL: self.entry)
            case 1: self.webView.loadSimulatedRequest(URLRequest(url: self.entry), responseHTML: String(decoding: html, as: UTF8.self))
            default: self.webView.load(URLRequest(url: self.entry))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.inspect() }
        }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        record(["mode": modes[index], "event": "script", "data": message.body])
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        record(["mode": modes[index], "event": "loadStop", "urlMatches": webView.url == entry])
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(["mode": modes[index], "event": "loadError", "error": String(describing: error)])
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept only this disposable loopback fixture certificate.
        if challenge.protectionSpace.host == "localhost", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func inspect() {
        guard !finished else { return }
        finished = true
        webView.evaluateJavaScript("""
          (()=>({href:location.href,origin:location.origin,secure:isSecureContext,
          mounted:window.fixtureMounted===true,stage:document.querySelector('[data-role=stage]')?.textContent||'',
          detail:document.querySelector('[data-role=detail]')?.textContent||'',
          crypto:!!crypto.subtle,deflateRaw:(()=>{try{return !!new DecompressionStream('deflate-raw').readable}catch{return false}})()}))()
          """) { value, error in
            self.record(["mode": self.modes[self.index], "event": "result", "value": value ?? NSNull(), "error": error.map(String.init(describing:)) ?? ""])
            self.webView.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
            self.window.orderOut(nil)
            self.webView = nil
            self.window = nil
            self.index += 1
            if self.index < self.modes.count { self.start() }
            else { NSApplication.shared.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
DispatchQueue.main.async { probe.start() }
app.run()
