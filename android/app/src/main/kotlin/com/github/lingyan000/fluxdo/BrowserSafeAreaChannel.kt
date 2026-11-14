package com.github.lingyan000.fluxdo

import android.os.Build
import android.view.View
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.WeakHashMap

/** 浏览器原生容器只向网页下发尚未由 Flutter 承担的安全区，保留 IME。 */
class BrowserSafeAreaChannel(private val engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.fluxdo/browser_safe_area")
    // 不持有保活实例；标签页关闭后，插件仍可正常回收整个视图树。
    private val containers = WeakHashMap<View, Unit>()

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "setHandledEdges") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val keepAliveId = call.argument<String>("keepAliveId")
            val left = call.argument<Boolean>("left")
            val top = call.argument<Boolean>("top")
            val right = call.argument<Boolean>("right")
            val bottom = call.argument<Boolean>("bottom")
            if (keepAliveId == null || left == null || top == null || right == null || bottom == null) {
                result.error("INVALID_EDGES", "浏览器安全区参数不完整", null)
                return@setMethodCallHandler
            }
            val plugin = engine.plugins.get(InAppWebViewFlutterPlugin::class.java) as? InAppWebViewFlutterPlugin
            val container = plugin?.inAppWebViewManager?.keepAliveWebViews?.get(keepAliveId)?.view
            if (container == null) {
                result.error("WEBVIEW_NOT_FOUND", "浏览器原生实例不存在", null)
                return@setMethodCallHandler
            }

            // 装在插件的容器上，保留 WebView 自己的 Insets 监听器，兼容旧 Android。
            // 返回更新后的 Insets，而非 CONSUMED，确保已有 env() 数值也能收到归零通知。
            ViewCompat.setOnApplyWindowInsetsListener(container) { _, insets ->
                fun remaining(value: Insets) = Insets.of(
                    if (left) 0 else value.left,
                    if (top) 0 else value.top,
                    if (right) 0 else value.right,
                    if (bottom) 0 else value.bottom,
                )
                // Android 28/29 的 getInsets(displayCutout) 仍读取 DisplayCutout 对象，
                // 仅 setInsets 无法清掉它。完全由应用承担时单独清除刘海类型；
                // 其余 Insets 仍继续下发，不会阻断 WebView 的归零或键盘通知。
                val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
                @Suppress("DEPRECATION")
                val base = if (remaining(cutout) == Insets.NONE) insets.consumeDisplayCutout() else insets
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    // Android 10 及以下用同一组 systemWindowInsets 表示导航栏和 IME。
                    // 不能用 setInsets(navigationBars, 0) 覆盖正在显示的键盘高度；
                    // 保留原始 stableInsets，供 WebView 继续区分键盘与导航栏。
                    @Suppress("DEPRECATION")
                    val system = insets.systemWindowInsets
                    val safe = remaining(system)
                    val bottomInset = if (insets.getInsets(WindowInsetsCompat.Type.ime()).bottom > 0) {
                        system.bottom
                    } else {
                        safe.bottom
                    }
                    @Suppress("DEPRECATION")
                    val legacy = WindowInsetsCompat.Builder(base)
                        .setSystemWindowInsets(Insets.of(safe.left, safe.top, safe.right, bottomInset))
                        .build()
                    return@setOnApplyWindowInsetsListener legacy
                }
                val builder = WindowInsetsCompat.Builder(base)
                for (type in intArrayOf(
                    WindowInsetsCompat.Type.statusBars(),
                    WindowInsetsCompat.Type.navigationBars(),
                    WindowInsetsCompat.Type.captionBar(),
                    WindowInsetsCompat.Type.displayCutout(),
                )) {
                    builder.setInsets(type, remaining(insets.getInsets(type)))
                    builder.setInsetsIgnoringVisibility(type, remaining(insets.getInsetsIgnoringVisibility(type)))
                }
                // 不改 ime、systemGestures 等类型，输入法与系统手势仍由原有流程处理。
                builder.build()
            }
            containers[container] = Unit
            ViewCompat.requestApplyInsets(container)
            result.success(true)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        for (container in containers.keys.toList()) {
            ViewCompat.setOnApplyWindowInsetsListener(container, null)
            ViewCompat.requestApplyInsets(container)
        }
        containers.clear()
    }
}
