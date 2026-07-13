package com.github.lingyan000.fluxdo

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 媒体转码通道 Android 腿(音视频压缩到站点 4MB 上限):
 * media3 Transformer,底层系统 MediaCodec 硬编,码率经 VideoEncoderSettings/
 * AudioEncoderSettings 精确指定。与 Dart 侧 MediaTranscoder 协议对应。
 *
 * 已知偏差(与 Apple/ffmpeg 腿相比,码率主导下可接受):
 * - 不降帧(Transformer 无逐帧丢帧 API);
 * - 不重采样/混单声道(audioSampleRate/audioChannels 参数忽略)。
 */
@UnstableApi
object MediaTranscodeChannel {
    private const val CHANNEL = "com.fluxdo/media_transcode"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var transformer: Transformer? = null
    private var pendingResult: MethodChannel.Result? = null
    private val progressHolder = ProgressHolder()
    @Volatile private var lastProgress = 0.0
    private var ticker: Runnable? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> probe(call.arguments as? String, result)
                "transcode" -> {
                    @Suppress("UNCHECKED_CAST")
                    transcode(context, call.arguments as? Map<String, Any?>, result)
                }
                "progress" -> {
                    transformer?.let {
                        if (it.getProgress(progressHolder) != Transformer.PROGRESS_STATE_UNAVAILABLE) {
                            lastProgress = progressHolder.progress / 100.0
                        }
                    }
                    result.success(lastProgress)
                }
                "cancel" -> {
                    val t = transformer
                    transformer = null
                    t?.cancel()
                    // 取消后 Transformer 不再回调,悬空的 transcode 结果按
                    // "被取消"收口(Dart 侧契约:false = cancelled)
                    finish { it.success(false) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private inline fun finish(crossinline reply: (MethodChannel.Result) -> Unit) {
        val r = pendingResult ?: return
        pendingResult = null
        reply(r)
    }

    private fun probe(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.success(null)
            return
        }
        Thread {
            var out: Map<String, Any?>? = null
            try {
                val r = MediaMetadataRetriever()
                r.setDataSource(path)
                val durationMs = r
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                val hasVideo =
                    r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
                val width = r
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toIntOrNull()
                val height = r
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toIntOrNull()
                r.release()
                if (durationMs != null && durationMs > 0) {
                    out = mapOf(
                        "durationMs" to durationMs.toInt(),
                        "hasVideo" to hasVideo,
                        "width" to width,
                        "height" to height,
                    )
                }
            } catch (_: Exception) {
            }
            mainHandler.post { result.success(out) }
        }.start()
    }

    private fun transcode(
        context: Context,
        args: Map<String, Any?>?,
        result: MethodChannel.Result,
    ) {
        if (args == null) {
            result.error("ARGS", "参数缺失", null)
            return
        }
        if (transformer != null) {
            result.error("BUSY", "已有转码任务进行中", null)
            return
        }
        val input = args["input"] as? String
        val output = args["output"] as? String
        if (input == null || output == null) {
            result.error("ARGS", "input/output 缺失", null)
            return
        }
        val audioOnly = args["audioOnly"] as? Boolean ?: false
        val audioBitrate = (args["audioBitrate"] as? Number)?.toInt() ?: 64000
        val videoBitrate = (args["videoBitrate"] as? Number)?.toInt()
        val maxHeight = (args["maxHeight"] as? Number)?.toInt()

        lastProgress = 0.0
        pendingResult = result
        File(output).delete()

        val edited = EditedMediaItem.Builder(
            MediaItem.fromUri(Uri.fromFile(File(input)))
        ).apply {
            if (audioOnly) {
                setRemoveVideo(true)
            } else if (maxHeight != null) {
                setEffects(
                    Effects(listOf(), listOf(Presentation.createForHeight(maxHeight)))
                )
            }
        }.build()

        val encoderFactory = DefaultEncoderFactory.Builder(context).apply {
            if (videoBitrate != null) {
                setRequestedVideoEncoderSettings(
                    VideoEncoderSettings.Builder().setBitrate(videoBitrate).build()
                )
            }
            setRequestedAudioEncoderSettings(
                AudioEncoderSettings.Builder().setBitrate(audioBitrate).build()
            )
        }.build()

        val t = Transformer.Builder(context)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .apply { if (!audioOnly) setVideoMimeType(MimeTypes.VIDEO_H264) }
            .setEncoderFactory(encoderFactory)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(
                    composition: Composition,
                    exportResult: ExportResult,
                ) {
                    stopTicker()
                    transformer = null
                    lastProgress = 1.0
                    finish { it.success(true) }
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    stopTicker()
                    transformer = null
                    File(output).delete()
                    finish { it.error("TRANSCODE", exportException.message, null) }
                }
            })
            .build()
        transformer = t
        t.start(edited, output)
        startTicker()
    }

    private fun startTicker() {
        stopTicker()
        val tick = object : Runnable {
            override fun run() {
                val t = transformer ?: return
                if (t.getProgress(progressHolder) != Transformer.PROGRESS_STATE_UNAVAILABLE) {
                    lastProgress = progressHolder.progress / 100.0
                }
                mainHandler.postDelayed(this, 300)
            }
        }
        ticker = tick
        mainHandler.postDelayed(tick, 300)
    }

    private fun stopTicker() {
        ticker?.let { mainHandler.removeCallbacks(it) }
        ticker = null
    }
}
