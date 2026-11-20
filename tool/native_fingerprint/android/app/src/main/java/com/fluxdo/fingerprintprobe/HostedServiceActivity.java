package com.fluxdo.fingerprintprobe;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.net.Uri;
import android.net.http.SslError;
import android.webkit.*;
import org.json.*;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

// 仅诊断 APK 使用：公开 JSON 接口最多三次导航，正常证书信任，不登录或修改 QUIC 参数。
public final class HostedServiceActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final JSONArray attempts = new JSONArray();
    private WebView view;
    private Uri target;
    private int round;
    private int httpStatus;
    private int sslErrors;
    private boolean captured;
    private boolean finished;
    private String nativeUa;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        target = Uri.parse(getIntent().getStringExtra("url"));
        if (!"https".equals(target.getScheme()) || target.getHost() == null ||
            target.getUserInfo() != null || target.getQuery() != null || target.getFragment() != null ||
            (target.getPort() != -1 && target.getPort() != 443)) { finish(); return; }
        view = new WebView(this);
        setContentView(view);
        CookieManager.getInstance().setAcceptCookie(false);
        view.getSettings().setJavaScriptEnabled(true);
        view.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
        nativeUa = view.getSettings().getUserAgentString();
        view.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                return !target.equals(request.getUrl());
            }
            @Override public void onReceivedSslError(WebView v, SslErrorHandler handler, SslError error) {
                sslErrors++; handler.cancel(); save(round, null, "certificate " + error.getPrimaryError());
            }
            @Override public void onReceivedError(WebView v, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) save(round, null, "navigation " + error.getErrorCode());
            }
            @Override public void onReceivedHttpError(WebView v, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame()) httpStatus = response.getStatusCode();
            }
            @Override public void onPageFinished(WebView v, String url) {
                if (captured || !target.toString().equals(url)) return;
                final int token = round;
                v.evaluateJavascript("JSON.stringify({protocol:(performance.getEntriesByType('navigation')[0]||{}).nextHopProtocol||'',body:(document.body?document.body.innerText:'').slice(0,262144)})", value -> {
                    try {
                        Object decoded = new JSONTokener(value).nextValue();
                        save(token, new JSONObject((String) decoded), null);
                    } catch (Exception error) { save(token, null, "document result unavailable"); }
                });
            }
        });
        navigate();
    }

    private void navigate() {
        if (finished) return;
        round++; captured = false; httpStatus = 0;
        final int token = round;
        view.loadUrl(target.toString());
        handler.postDelayed(() -> save(token, null, "navigation timeout"), 12000);
    }

    private void save(int token, JSONObject response, String error) {
        if (finished || captured || token != round) return;
        captured = true;
        try {
            JSONObject entry = response == null ? new JSONObject() : response;
            entry.put("attempt", round); entry.put("http_error_status", httpStatus);
            entry.put("error", error == null ? JSONObject.NULL : error);
            attempts.put(entry);
            view.stopLoading();
            if (round < 3 && sslErrors == 0) { handler.postDelayed(this::navigate, 1500); return; }
            finished = true;
            JSONObject result = new JSONObject();
            result.put("engine", "Android WebView"); result.put("os", android.os.Build.VERSION.RELEASE);
            result.put("webview", WebView.getCurrentWebViewPackage().versionName);
            result.put("user_agent", nativeUa); result.put("url", target.toString());
            result.put("ssl_errors", sslErrors); result.put("certificate_bypass", false);
            result.put("forced_quic", false); result.put("attempts", attempts);
            Files.write(new File(getFilesDir(), "hosted-result.json").toPath(), result.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception failure) { android.util.Log.e("HostedProbe", "Cannot save result", failure); }
        finish();
    }

    @Override protected void onDestroy() {
        finished = true; handler.removeCallbacksAndMessages(null);
        if (view != null) { view.stopLoading(); view.destroy(); }
        super.onDestroy();
    }
}
