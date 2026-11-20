package com.github.lingyan000.fluxdo

import android.graphics.Bitmap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.aomedia.avif.android.AvifDecoder
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * AVIF 解码通道(Android):libavif + dav1d 在后台任务队列里解码。
 *
 * 不用 Flutter 引擎的系统解码路径:引擎对 Skia 不认识的格式(AVIF)走
 * AndroidImageGenerator,把整次解码投到唯一的 IO 线程后让 UI 线程等待图片头
 * 解析完;IO 线程串行,前一张还在解码时 UI 线程就一直被卡住,滚动掉帧。
 * 系统 ImageDecoder 也不设目标尺寸,总是全尺寸解出再缩。
 *
 * 这里在并发后台任务队列中执行,既不占 Android 主线程也不占 Flutter UI
 * 线程;传入 maxDim 时 libavif 先在 YUV 阶段用 libyuv 缩到目标尺寸再转 RGB。
 *
 * 输出两种:
 * - rgba:预乘 RGBA 像素(与 dart:ui PixelFormat.rgba8888 一致),给需要直接
 *   显示的大图;
 * - png:编码好的小图,给表情缩略图直接写缓存(不必再从 GPU 读回重新编码)。
 */
object AndroidAvifChannel {
    private const val CHANNEL = "com.fluxdo/avif"

    fun register(messenger: BinaryMessenger) {
        val queue = messenger.makeBackgroundTaskQueue(
            BinaryMessenger.TaskQueueOptions().setIsSerial(false)
        )
        MethodChannel(messenger, CHANNEL, StandardMethodCodec.INSTANCE, queue)
            .setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "decode" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("bad_args", "bytes is required", null)
                    return
                }
                val maxDim = call.argument<Int>("maxDim") ?: 0
                val png = call.argument<Boolean>("png") ?: false
                try {
                    result.success(decode(bytes, maxDim, png))
                } catch (e: Throwable) {
                    result.error("decode_failed", e.toString(), null)
                }
            }
            "version" -> result.success(AvifDecoder.versionString())
            else -> result.notImplemented()
        }
    }

    /** 解出首帧(动画取第一帧);无法解码时返回 null。 */
    private fun decode(bytes: ByteArray, maxDim: Int, png: Boolean): Map<String, Any>? {
        // libavif 要求 direct buffer 且 position 为 0
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()

        val info = AvifDecoder.Info()
        if (!AvifDecoder.getInfo(buffer, bytes.size, info)) return null
        if (info.width <= 0 || info.height <= 0) return null

        var width = info.width
        var height = info.height
        if (maxDim > 0 && (width > maxDim || height > maxDim)) {
            if (width >= height) {
                height = maxOf(1, Math.round(height.toDouble() * maxDim / width).toInt())
                width = maxDim
            } else {
                width = maxOf(1, Math.round(width.toDouble() * maxDim / height).toInt())
                height = maxDim
            }
        }

        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            // 单线程解码:并发由 Dart 侧限流,多张图并行,不让一张图占满所有核
            if (!AvifDecoder.decode(buffer, bytes.size, bitmap, 1)) return null
            return if (png) {
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                mapOf("png" to out.toByteArray(), "width" to width, "height" to height)
            } else {
                val pixels = ByteBuffer.allocate(bitmap.byteCount)
                bitmap.copyPixelsToBuffer(pixels)
                mapOf("rgba" to pixels.array(), "width" to width, "height" to height)
            }
        } finally {
            bitmap.recycle()
        }
    }
}
