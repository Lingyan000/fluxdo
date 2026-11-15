package com.github.lingyan000.fluxdo

import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.ViewTreeObserver
import androidx.core.view.ViewCompat
import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.WeakHashMap

/** 原生视图自身观察几何变化，不依赖工具栏显隐开关或逐帧 Dart 通道消息。 */
class BrowserSafeAreaChannel(private val engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.fluxdo/browser_safe_area")
    private val bindings = WeakHashMap<View, BrowserInsetsBinding>()

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "attach") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val id = call.argument<String>("keepAliveId")
            val plugin = engine.plugins.get(InAppWebViewFlutterPlugin::class.java) as? InAppWebViewFlutterPlugin
            val instance = plugin?.inAppWebViewManager?.keepAliveWebViews?.get(id)
            val webView = instance?.webView
            val container = instance?.view
            if (webView == null || container == null) {
                result.error("WEBVIEW_NOT_FOUND", "浏览器原生实例不存在", null)
                return@setMethodCallHandler
            }
            // Android 12+ 调整后显式交给 WebView 默认入口更新内核；
            // 旧系统保留 WebView 内部监听器，改在父容器处理。
            val target = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) webView else container
            val binding = bindings.getOrPut(target) { BrowserInsetsBinding(target, webView) }
            binding.refresh()
            result.success(true)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        bindings.values.toList().forEach { it.dispose() }
        bindings.clear()
    }
}

private data class BrowserNativeGeometry(val viewport: Rect, val window: Rect, val fullscreen: Boolean)

private class BrowserInsetsBinding(target: View, webView: InAppWebView) :
    View.OnAttachStateChangeListener, ViewTreeObserver.OnPreDrawListener {
    private val targetRef = WeakReference(target)
    private val webViewRef = WeakReference(webView)
    private var observer: ViewTreeObserver? = null
    private var last: BrowserNativeGeometry? = null

    init {
        installBrowserWindowInsetsListener(target) { insets ->
            val geometry = geometry()
            if (geometry == null) insets else
                browserWindowInsets(insets, geometry.viewport, geometry.window, geometry.fullscreen)
        }
        target.addOnAttachStateChangeListener(this)
        if (target.isAttachedToWindow) onViewAttachedToWindow(target)
    }

    private fun geometry(): BrowserNativeGeometry? {
        val webView = webViewRef.get() ?: return null
        if (!webView.isAttachedToWindow || webView.width == 0 || webView.height == 0) return null
        fun bounds(view: View): Rect {
            val location = IntArray(2)
            view.getLocationInWindow(location)
            return Rect(location[0], location[1], location[0] + view.width, location[1] + view.height)
        }
        // rootView 与 WebView 使用同一个窗口坐标系，分屏和浮动窗口无需屏幕尺寸常量。
        return BrowserNativeGeometry(bounds(webView), bounds(webView.rootView), webView.isInFullscreen)
    }

    fun refresh() {
        last = null
        targetRef.get()?.let { ViewCompat.requestApplyInsets(it) }
    }

    override fun onPreDraw(): Boolean {
        val current = geometry()
        if (current != null && current != last) {
            last = current
            targetRef.get()?.let { ViewCompat.requestApplyInsets(it) }
        }
        return true
    }

    override fun onViewAttachedToWindow(view: View) {
        removeObserver()
        observer = view.viewTreeObserver.also { it.addOnPreDrawListener(this) }
        refresh()
    }

    override fun onViewDetachedFromWindow(view: View) {
        removeObserver()
        last = null
    }

    private fun removeObserver() {
        observer?.takeIf { it.isAlive }?.removeOnPreDrawListener(this)
        observer = null
    }

    fun dispose() {
        removeObserver()
        targetRef.get()?.let {
            it.removeOnAttachStateChangeListener(this)
            ViewCompat.setOnApplyWindowInsetsListener(it, null)
            ViewCompat.requestApplyInsets(it)
        }
    }
}
