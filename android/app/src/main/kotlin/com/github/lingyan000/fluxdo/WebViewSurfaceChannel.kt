package com.github.lingyan000.fluxdo

import android.graphics.Bitmap
import android.graphics.Canvas
import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 低开销读取保活 WebView 的可视画面，供玻璃底图、取色与弹窗模糊使用。
 *
 * 插件的 takeScreenshot 在主线程上先按 WebView 全分辨率软件绘制整页，再缩小、
 * 再 PNG 压缩；小程序侧栏的玻璃每 160ms 取一次，会占满 WebView 与混合合成共用
 * 的主线程。这里直接按目标宽度缩小画布后绘制（工作量随像素数下降），返回原始
 * RGBA 像素，不压缩也不需要 Dart 侧解码。
 *
 * 仍绘制完整可视区域：只画局部会让网页里嵌套 frame 停止响应滚动（见 Dart 侧
 * WebViewSurfaceCapture 的说明），裁切交给 Flutter。
 */
class WebViewSurfaceChannel(private val engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.fluxdo/webview_surface")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "capture") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val id = call.argument<String>("keepAliveId")
            val width = call.argument<Int>("width") ?: 0
            val plugin = engine.plugins.get(InAppWebViewFlutterPlugin::class.java) as? InAppWebViewFlutterPlugin
            val webView = plugin?.inAppWebViewManager?.keepAliveWebViews?.get(id)?.webView
            if (webView == null || width < 1 || !webView.isAttachedToWindow ||
                webView.width == 0 || webView.height == 0
            ) {
                result.success(null)
                return@setMethodCallHandler
            }
            try {
                val scale = width.toFloat() / webView.width
                val bitmapWidth = max(1, (webView.width * scale).roundToInt())
                val bitmapHeight = max(1, (webView.height * scale).roundToInt())
                val bitmap = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
                try {
                    val canvas = Canvas(bitmap)
                    canvas.scale(scale, scale)
                    canvas.translate(-webView.scrollX.toFloat(), -webView.scrollY.toFloat())
                    webView.draw(canvas)
                    // ARGB_8888 在内存里按 R、G、B、A 排列，对应 Flutter 的 rgba8888
                    val pixels = ByteBuffer.allocate(bitmap.byteCount)
                    bitmap.copyPixelsToBuffer(pixels)
                    result.success(
                        mapOf(
                            "width" to bitmapWidth,
                            "height" to bitmapHeight,
                            "pixels" to pixels.array(),
                        )
                    )
                } finally {
                    bitmap.recycle()
                }
            } catch (e: RuntimeException) {
                // 原生视图恢复期间可能暂不可绘制，Dart 侧退回插件截图
                result.success(null)
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
