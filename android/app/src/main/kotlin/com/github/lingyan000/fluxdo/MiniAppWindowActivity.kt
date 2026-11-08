package com.github.lingyan000.fluxdo

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.lang.ref.WeakReference
import java.text.BreakIterator

/** 每个文档任务拥有完整 Flutter 运行页；Intent 只保存应用 ID。 */
internal object MiniAppWindows {
    data class Entry(val url: String, val name: String, val key: String, val icon: Bitmap)
    val entries = mutableMapOf<String, Entry>()
    val activities = mutableMapOf<String, WeakReference<MiniAppWindowActivity>>()
    var channel: MethodChannel? = null
        private set

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        invalidate(activity)
        channel = MethodChannel(messenger, "com.fluxdo/mini_app_windows").also { bridge ->
            bridge.setMethodCallHandler { call, reply ->
                when (call.method) {
                    "getLaunch" -> reply.success(null)
                    "invalidate" -> { invalidate(activity); reply.success(null) }
                    "open" -> try {
                        val id = requireNotNull(call.argument<String>("id"))
                        require(UUID.fromString(id).toString().equals(id, ignoreCase = true))
                        val url = requireNotNull(call.argument<String>("url"))
                        val uri = java.net.URI(url)
                        require(uri.scheme == "https" && uri.rawAuthority == "linux.do" &&
                            uri.rawPath == "/apps/$id" && url.length <= 16384)
                        val key = requireNotNull(call.argument<String>("key"))
                        val name = call.argument<String>("name")?.take(80).orEmpty().ifBlank { "FluxDO" }
                        val icon = entries[id]?.takeIf { it.key == key }?.icon ?: fallbackIcon(id, name)
                        entries[id] = Entry(url, name, key, icon)
                        activity.startActivity(Intent(activity, MiniAppWindowActivity::class.java).apply {
                            data = Uri.Builder().scheme("fluxdo-miniapp").authority("task").appendPath(id).build()
                            addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
                        })
                        reply.success(true)
                    } catch (_: Exception) { reply.error("OPEN_FAILED", "Cannot open mini app window", null) }
                    "updateIcon" -> try {
                        val id = requireNotNull(call.argument<String>("id"))
                        val entry = entries[id]
                        if (entry == null || entry.key != call.argument<String>("key")) {
                            reply.error("SESSION_REVOKED", null, null)
                        } else {
                            val bytes = requireNotNull(call.argument<ByteArray>("icon"))
                            require(bytes.size <= 65536)
                            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                            require(bounds.outWidth in 1..192 && bounds.outHeight in 1..192)
                            val icon = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
                            entries[id] = entry.copy(icon = icon)
                            activities[id]?.get()?.describeTask()
                            reply.success(null)
                        }
                    } catch (_: Exception) { reply.error("INVALID_ICON", null, null) }
                    else -> reply.notImplemented()
                }
            }
        }
    }
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        entries.clear()
        activities.clear()
    }
    fun changed(id: String) { channel?.invokeMethod("updated", id) }
    private fun invalidate(activity: Activity) {
        entries.clear()
        activities.clear()
        val manager = activity.getSystemService(Activity.ACTIVITY_SERVICE) as ActivityManager
        manager.appTasks.filter {
            it.taskInfo.baseIntent.component?.className == MiniAppWindowActivity::class.java.name
        }.forEach { it.finishAndRemoveTask() }
    }

    private fun fallbackIcon(id: String, name: String): Bitmap {
        val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        // 网络未返回前仍能区分任务，不借用客户端图标冒充小程序。
        val hue = (id.hashCode().toLong() and 0x7fffffff).rem(360).toFloat()
        paint.color = Color.HSVToColor(floatArrayOf(hue, .18f, .94f))
        canvas.drawRoundRect(0f, 0f, 96f, 96f, 29f, 29f, paint)
        paint.color = Color.HSVToColor(floatArrayOf(hue, .42f, .32f))
        paint.textSize = 42f
        paint.textAlign = Paint.Align.CENTER
        paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        val text = name.trim()
        val iterator = BreakIterator.getCharacterInstance().apply { setText(text) }
        val first = text.substring(0, iterator.next()).uppercase()
        canvas.drawText(first, 48f, 48f - (paint.ascent() + paint.descent()) / 2f, paint)
        return bitmap
    }
}

class MiniAppWindowActivity : FlutterActivity() {
    private val id: String? get() = intent.data?.lastPathSegment
    private var bridge: MethodChannel? = null
    private var controls: MethodChannel? = null
    private var taskColor = 0
    // FlutterEngineGroup 的默认启动路径仅取根库入口名，不能依赖 libraryUri。
    override fun getDartEntrypointFunctionName() = "androidMiniAppWindowMain"
    // 文档任务 URI 只标识系统任务，不是 Flutter 内部路由。
    override fun getInitialRoute() = "/"
    override fun shouldHandleDeeplinking() = false

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        bridge = MethodChannel(engine.dartExecutor.binaryMessenger, "com.fluxdo/mini_app_windows").also { child ->
            child.setMethodCallHandler { call, reply ->
                val entry = MiniAppWindows.entries[id]
                if (entry == null) { reply.error("SESSION_REVOKED", null, null); finishAndRemoveTask() }
                else if (call.method == "getLaunch") reply.success(entry.key)
                else {
                    val host = MiniAppWindows.channel
                    if (host == null) reply.error("SESSION_REVOKED", null, null)
                    else {
                        host.invokeMethod(call.method, call.arguments, reply)
                        if (call.method == "community") startActivity(Intent(this, MainActivity::class.java).apply {
                            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                        })
                    }
                }
            }
        }
        controls = MethodChannel(engine.dartExecutor.binaryMessenger, "com.fluxdo/mini_app_window_controls").also {
            it.setMethodCallHandler { call, reply ->
                if (call.method == "close") { reply.success(null); finishAndRemoveTask() }
                else reply.notImplemented()
            }
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        id?.let { MiniAppWindows.activities[it] = WeakReference(this) }
        describeTask()
    }
    @Suppress("DEPRECATION")
    internal fun describeTask() {
        val entry = MiniAppWindows.entries[id]
        if (entry == null) { finishAndRemoveTask(); return }
        title = entry.name
        setTaskDescription(ActivityManager.TaskDescription(entry.name, entry.icon, taskColor))
    }
    @Suppress("DEPRECATION")
    override fun setTaskDescription(description: ActivityManager.TaskDescription) {
        val entry = MiniAppWindows.entries[id]
        taskColor = description.primaryColor
        // Flutter 的 Title 在首帧和主题更新时会传入无图标的 TaskDescription。
        // 颜色跟随 Flutter，任务身份始终由本窗口绑定的应用决定。
        super.setTaskDescription(if (entry == null) description else
            ActivityManager.TaskDescription(entry.name, entry.icon, description.primaryColor))
    }
    override fun onNewIntent(next: Intent) {
        super.onNewIntent(next)
        setIntent(next)
        describeTask()
        MiniAppWindows.entries[id]?.let { bridge?.invokeMethod("activate", it.url) }
    }
    override fun onResume() {
        super.onResume()
        describeTask()
    }
    override fun onPause() {
        id?.let(MiniAppWindows::changed)
        super.onPause()
    }
    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        bridge?.setMethodCallHandler(null)
        controls?.setMethodCallHandler(null)
        super.cleanUpFlutterEngine(engine)
    }
    override fun onDestroy() {
        id?.let { key ->
            if (MiniAppWindows.activities[key]?.get() === this) MiniAppWindows.activities.remove(key)
        }
        if (isFinishing) id?.let { key ->
            MiniAppWindows.entries.remove(key)?.let { entry ->
                MiniAppWindows.channel?.invokeMethod("closed", mapOf("key" to entry.key))
            }
        }
        super.onDestroy()
    }
}
