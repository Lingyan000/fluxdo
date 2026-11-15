package com.fluxdo.fingerprintprobe;

import android.app.Activity;
import android.os.Bundle;
import android.net.Uri;
import android.net.http.SslError;
import android.webkit.*;
import android.util.Log;
import org.json.JSONObject;

// 诊断专用 Activity，只接受 adb reverse 映射的 localhost 探针。
public final class ProbeActivity extends Activity {
    private WebView view;
    private Uri target;
    private boolean finished;
    private String nativeUa;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        target = Uri.parse(getIntent().getStringExtra("url"));
        if (!"https".equals(target.getScheme()) || !"localhost".equals(target.getHost()) || !"/fluxdo-probe".equals(target.getPath())) { finish(); return; }
        view = new WebView(this);
        setContentView(view);
        view.getSettings().setJavaScriptEnabled(true);
        view.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
        nativeUa = view.getSettings().getUserAgentString();
        if ("app".equals(getIntent().getStringExtra("mode"))) {
            view.getSettings().setUserAgentString(nativeUa.replaceAll("[;\\s]*\\bwv\\b[;\\s]*(?=\\))", "").replaceAll("Version/[^ ]+ *", ""));
        }
        view.setWebViewClient(new WebViewClient() {
            @Override public void onReceivedSslError(WebView v, SslErrorHandler handler, SslError error) {
                Uri url = Uri.parse(error.getUrl());
                if (url.getHost().equals(target.getHost()) && url.getPort() == target.getPort() && "https".equals(url.getScheme())) handler.proceed();
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
            data.put("success", error == null);
            data.put("error", error);
            Log.i("FluxdoProbeResult", data.toString());
        } catch (Exception e) { Log.e("FluxdoProbeResult", "{\"success\":false}", e); }
        finish();
    }
    @Override protected void onDestroy() {
        if (view != null) view.destroy();
        super.onDestroy();
    }
}
