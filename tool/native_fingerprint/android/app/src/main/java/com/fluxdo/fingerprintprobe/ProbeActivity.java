package com.fluxdo.fingerprintprobe;

import android.app.Activity;
import android.os.Bundle;
import android.net.Uri;
import android.net.http.SslError;
import android.webkit.*;
import android.util.Log;
import org.json.JSONObject;

// 诊断专用 Activity：本地探针或显式指定的 tailnet 可信证书探针。
public final class ProbeActivity extends Activity {
    private WebView view;
    private Uri target;
    private boolean finished;
    private String nativeUa;
    private UdpBridge udpBridge;
    private boolean trustedCertificateRequired;
    private int sslErrors;
    private int sslErrorsProceeded;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        target = Uri.parse(getIntent().getStringExtra("url"));
        String trustedHost = getIntent().getStringExtra("trustedHost");
        trustedCertificateRequired = trustedHost != null && trustedHost.matches("[a-z0-9][a-z0-9-]*\\.[a-z0-9-]+\\.ts\\.net") && trustedHost.equals(target.getHost());
        if (!"https".equals(target.getScheme()) || (!"localhost".equals(target.getHost()) && !trustedCertificateRequired) || (!"/fluxdo-probe".equals(target.getPath()) && !"/fluxdo-h3".equals(target.getPath()))) { finish(); return; }
        view = new WebView(this);
        setContentView(view);
        view.getSettings().setJavaScriptEnabled(true);
        view.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
        nativeUa = view.getSettings().getUserAgentString();
        if ("app".equals(getIntent().getStringExtra("mode"))) {
            view.getSettings().setUserAgentString(nativeUa.replaceAll("[;\\s]*\\bwv\\b[;\\s]*(?=\\))", "").replaceAll("Version/[^ ]+ *", ""));
        }
        view.setWebViewClient(new WebViewClient() {
            @Override public void onReceivedError(WebView v, WebResourceRequest request, WebResourceError error) {
                // 主文档失败时直接保留原生错误，避免只剩等待超时。
                if (request.isForMainFrame()) complete("navigation " + error.getErrorCode() + ": " + error.getDescription());
            }
            @Override public void onReceivedSslError(WebView v, SslErrorHandler handler, SslError error) {
                sslErrors++;
                if (trustedCertificateRequired) {
                    handler.cancel();
                    complete("certificate " + error.getPrimaryError());
                    return;
                }
                Uri url = Uri.parse(error.getUrl());
                if (url.getHost().equals(target.getHost()) && url.getPort() == target.getPort() && "https".equals(url.getScheme())) { sslErrorsProceeded++; handler.proceed(); }
                else handler.cancel();
            }
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                Uri url = request.getUrl();
                return !target.getHost().equals(url.getHost()) || target.getPort() != url.getPort() || !"https".equals(url.getScheme());
            }
        });
        view.setWebChromeClient(new WebChromeClient() {
            @Override public void onReceivedTitle(WebView v, String title) {
                if ("fluxdo-probe-done".equals(title)) complete(null);
            }
        });
        if (!trustedCertificateRequired && getIntent().getBooleanExtra("udpBridge", false)) {
            try { udpBridge = new UdpBridge(target.getPort()); }
            catch (Exception e) { complete("UDP bridge: " + e); return; }
        }
        view.loadUrl(target.toString());
        view.postDelayed(() -> complete("timeout"), 25000);
    }
    private void complete(String error) {
        if (finished) return;
        finished = true;
        try {
            JSONObject data = new JSONObject();
            data.put("engine", "native Android WebView");
            data.put("os", android.os.Build.VERSION.RELEASE);
            data.put("webview", WebView.getCurrentWebViewPackage().versionName);
            data.put("native_user_agent", nativeUa);
            data.put("effective_user_agent", view.getSettings().getUserAgentString());
            android.net.ConnectivityManager connectivity = getSystemService(android.net.ConnectivityManager.class);
            data.put("default_network_available", connectivity.getActiveNetwork() != null);
            data.put("udp_relay", udpBridge != null);
            data.put("trusted_certificate_required", trustedCertificateRequired);
            data.put("ssl_error_count", sslErrors);
            data.put("ssl_errors_proceeded", sslErrorsProceeded);
            if (udpBridge != null) {
                data.put("udp_dual_loopback", true);
                data.put("udp_sent", udpBridge.sent.get());
                data.put("udp_received", udpBridge.received.get());
                data.put("udp_error", udpBridge.error);
            }
            data.put("success", error == null);
            data.put("error", error);
            Log.i("FluxdoProbeResult", data.toString());
        } catch (Exception e) { Log.e("FluxdoProbeResult", "{\"success\":false}", e); }
        finish();
    }
    @Override protected void onDestroy() {
        if (udpBridge != null) udpBridge.close();
        if (view != null) view.destroy();
        super.onDestroy();
    }
}
