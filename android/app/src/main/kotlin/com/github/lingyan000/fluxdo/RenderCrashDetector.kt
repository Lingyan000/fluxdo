package com.github.lingyan000.fluxdo

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.opengl.EGL14
import android.os.Build
import android.util.Log

/**
 * Mali/Vulkan 渲染崩溃的本地自动识别。
 *
 * 背景:部分 Mali GPU 设备在 Impeller/Vulkan 的纹理/表面销毁路径上会触发
 * `mali-event-hand` 线程的 SIGABRT(destroyed mutex)。应用已提供
 * 「Skia/OpenGL ES 渲染兼容模式」开关(见 [MainActivity.provideFlutterEngine]),
 * 但用户不可能知道崩溃与这个开关有关 —— 必须由应用主动识别并提示。
 *
 * 与 [AnrTraceReporter] 的区别:那个是**上报**(依赖 Crashlytics 开关,只服务
 * 开发者);这个是**本地判断**(不依赖任何采集开关、零网络,服务所有用户)。
 * 两者都读 [ActivityManager.getHistoricalProcessExitReasons],但用途正交,
 * 各自维护自己的"已处理时间戳",互不干扰。
 *
 * ## 判定分级
 *
 * 不用"崩了几次"当唯一标准 —— 受影响用户崩一次往往就不敢再碰那个功能,
 * 等不到第二次。改为按**证据强度**分级:
 *
 * - **A 级(强证据)**:tombstone 里直接出现 [MALI_TRACE_MARKERS] 中的关键字
 *   (如 `libGLES_mali.so` / `mali-event-hand`)。崩溃栈直接指认 Mali GL 库,
 *   几乎不可能误报,**崩 1 次即提示**。
 * - **B 级(弱证据)**:tombstone 拿不到(API 30,或被全局环形缓冲挤掉),
 *   退化为"native 崩溃 + 致命信号 + 前台 + GPU 是 Mali"。这些条件都满足也
 *   仍可能是插件/JNI 崩溃,所以**累计 2 次才提示**。
 *
 * tombstone 只在 API 31+ 对 REASON_CRASH_NATIVE 返回,且因为是跨应用共享的
 * 环形缓冲,随时可能被别的应用的崩溃挤掉而返回 null —— B 级兜底不是可选项。
 */
object RenderCrashDetector {

    private const val TAG = "RenderCrashDetect"

    private const val PREFS_NAME = "render_crash_detector"

    /** 已扫描过的退出记录时间戳,避免重复计数同一次崩溃。 */
    private const val KEY_LAST_SCANNED_AT = "last_scanned_at"

    /** B 级弱证据的累计崩溃次数。 */
    private const val KEY_WEAK_HIT_COUNT = "weak_hit_count"

    /** 用户已明确选择「暂不开启」,不再自动弹窗。 */
    private const val KEY_USER_DISMISSED = "user_dismissed"

    /** 待消费的提示标记:native 侧检测到后置位,Dart 侧取走并弹窗。 */
    private const val KEY_SUGGESTION_PENDING = "suggestion_pending"

    /** 单次扫描最多看几条历史退出记录(系统最多保留 16 条)。 */
    private const val MAX_RECORDS = 8

    /** B 级弱证据需要累计多少次才提示。 */
    private const val WEAK_HIT_THRESHOLD = 2

    /**
     * tombstone 里出现即可判定为 A 级强证据的关键字。
     *
     * tombstone 是 protobuf,但其中的 so 路径、线程名都是明文 UTF-8 字符串
     * 字段,直接在原始字节里做子串搜索即可可靠命中,无需引入 protobuf 依赖
     * 去解析 schema(schema 还会随 Android 版本演进)。
     */
    private val MALI_TRACE_MARKERS = listOf(
        "libGLES_mali",
        "mali-event-hand",
        "libvulkan",
        "vulkan.mali",
        "libVkLayer",
    )

    /** tombstone 最多读多少字节 —— 只为找关键字,不需要全文。 */
    private const val TOMBSTONE_READ_LIMIT = 512 * 1024

    /**
     * 扫描上次进程退出记录,判断是否应当建议开启渲染兼容模式。
     *
     * 必须在后台线程调用:会读 tombstone(磁盘 IO)。
     *
     * @param gpuIdentity [detectGpuIdentity] 的结果,用于 B 级弱证据判定。
     * @return true 表示本次新识别出应提示(仅用于日志);实际提示与否由
     *         [consumePendingSuggestion] 决定。
     */
    fun scan(context: Context, gpuIdentity: String?): Boolean {
        // getHistoricalProcessExitReasons 需要 API 30+
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // 用户已经明确拒绝过,不再打扰(设置页仍保留「建议开启」提示)
        if (prefs.getBoolean(KEY_USER_DISMISSED, false)) return false

        // 兼容模式已经开着了,没什么可建议的
        if (isCompatModeEnabled(context)) return false

        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return false
            val records = am.getHistoricalProcessExitReasons(
                context.packageName, 0, MAX_RECORDS
            )
            if (records.isEmpty()) return false

            val lastScannedAt = prefs.getLong(KEY_LAST_SCANNED_AT, 0L)
            var newestSeen = lastScannedAt
            var strongHit = false
            var weakHits = 0

            // 系统按时间倒序返回;正序处理保证计数顺序自然
            for (info in records.reversed()) {
                if (info.timestamp <= lastScannedAt) continue
                if (info.timestamp > newestSeen) newestSeen = info.timestamp
                if (!isForegroundNativeCrash(info)) continue

                if (tombstoneMentionsMali(info)) {
                    strongHit = true
                    Log.i(TAG, "A 级强证据: tombstone 命中 Mali/Vulkan 关键字")
                } else if (isMaliGpu(gpuIdentity)) {
                    weakHits++
                    Log.i(TAG, "B 级弱证据: 前台 native 崩溃 + Mali GPU")
                }
            }

            if (newestSeen <= lastScannedAt) return false

            val editor = prefs.edit().putLong(KEY_LAST_SCANNED_AT, newestSeen)

            val totalWeak = prefs.getInt(KEY_WEAK_HIT_COUNT, 0) + weakHits
            editor.putInt(KEY_WEAK_HIT_COUNT, totalWeak)

            val shouldSuggest = strongHit || totalWeak >= WEAK_HIT_THRESHOLD
            if (shouldSuggest) {
                editor.putBoolean(KEY_SUGGESTION_PENDING, true)
                Log.i(
                    TAG,
                    "建议开启渲染兼容模式 (strong=$strongHit weakTotal=$totalWeak)"
                )
            }
            editor.apply()
            shouldSuggest
        } catch (e: Throwable) {
            // 检测功能本身绝不能影响启动
            Log.w(TAG, "扫描退出记录失败: ${e.message}")
            false
        }
    }

    /**
     * 取走待处理的提示标记(取走即清除,保证只弹一次)。
     */
    fun consumePendingSuggestion(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_SUGGESTION_PENDING, false)) return false
        prefs.edit().putBoolean(KEY_SUGGESTION_PENDING, false).apply()
        return true
    }

    /**
     * 是否曾经检测到过渲染崩溃 —— 设置页据此常驻显示「建议开启」。
     *
     * 与 [consumePendingSuggestion] 不同,这个标记不会被消费掉:用户点了
     * 「暂不开启」之后不再弹窗,但设置项上的建议仍然保留,方便他之后想起来。
     */
    fun hasDetectedRenderCrash(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SUGGESTION_PENDING, false) ||
            prefs.getBoolean(KEY_USER_DISMISSED, false) ||
            prefs.getInt(KEY_WEAK_HIT_COUNT, 0) >= WEAK_HIT_THRESHOLD
    }

    /** 记录用户明确拒绝,之后不再自动弹窗。 */
    fun markUserDismissed(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_USER_DISMISSED, true)
            .putBoolean(KEY_SUGGESTION_PENDING, false)
            .apply()
    }

    /**
     * 前台发生的 native 致命崩溃。
     *
     * 排除后台被回收(importance 非前台)与非 native 原因 —— Mali 渲染崩溃
     * 必然发生在有画面的前台。
     */
    private fun isForegroundNativeCrash(info: ApplicationExitInfo): Boolean {
        val nativeCrash = info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
            (info.reason == ApplicationExitInfo.REASON_SIGNALED && isFatalSignal(info.status))
        if (!nativeCrash) return false
        return info.importance <=
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
    }

    /** SIGABRT(6) / SIGSEGV(11) / SIGBUS(7) —— 渲染驱动崩溃的典型信号。 */
    private fun isFatalSignal(status: Int): Boolean = status == 6 || status == 11 || status == 7

    /**
     * 在 tombstone 原始字节里找 Mali/Vulkan 关键字。
     *
     * API 31+ 才对 REASON_CRASH_NATIVE 返回 tombstone;且该缓冲区是跨应用
     * 共享的环形队列,可能已被挤掉而返回 null —— 两种情况都退化到 B 级。
     */
    private fun tombstoneMentionsMali(info: ApplicationExitInfo): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            val text = info.traceInputStream?.use { stream ->
                // 不用 InputStream.readNBytes:那是 Java 11 API,在 Android 上要求
                // API 33+,而本检测需要支持 API 31+。手写循环零兼容风险。
                val buffer = ByteArray(16 * 1024)
                val sink = StringBuilder()
                var total = 0
                while (total < TOMBSTONE_READ_LIMIT) {
                    val read = stream.read(buffer)
                    if (read <= 0) break
                    total += read
                    // protobuf 的 string 字段是明文 UTF-8;ISO-8859-1 解码保证
                    // 字节与字符一一对应,不会因非法 UTF-8 序列丢字节。
                    // 关键字均为 ASCII,跨分块边界的风险由整体拼接规避。
                    sink.append(String(buffer, 0, read, Charsets.ISO_8859_1))
                }
                sink.toString()
            } ?: return false
            if (text.isEmpty()) return false
            MALI_TRACE_MARKERS.any { text.contains(it, ignoreCase = true) }
        } catch (e: Throwable) {
            Log.w(TAG, "读取 tombstone 失败: ${e.message}")
            false
        }
    }

    /** GPU 标识字符串是否表明这是 Mali GPU。 */
    private fun isMaliGpu(gpuIdentity: String?): Boolean =
        gpuIdentity?.contains("mali", ignoreCase = true) == true

    /** 兼容模式当前是否已开启(读 Dart 侧写入的同一份偏好)。 */
    private fun isCompatModeEnabled(context: Context): Boolean =
        context.getSharedPreferences(
            MainActivity.RENDER_GLES_PREFS_FILE, Context.MODE_PRIVATE
        ).getBoolean(MainActivity.RENDER_GLES_PREF_KEY, false)

    /**
     * 识别 GPU 厂商,**不依赖 EGL/GL context**。
     *
     * 注意不能用 `GLES20.glGetString(GL_RENDERER)`:那要求调用线程已经绑定
     * GL context,在启动扫描的后台线程上必然返回 null,会让 B 级判定永远
     * 失效(静默失效比报错更糟)。
     *
     * 采用双通道,任一命中即可:
     * 1. 系统属性 `ro.hardware.egl` / `ro.hardware` —— 厂商专门用来标识 GPU,
     *    零成本。但 `SystemProperties` 是 hidden API,Android 11+ 可能被
     *    灰名单拦截,所以用反射并容忍失败。
     * 2. [EGL14.eglQueryString] 查 EGL_VENDOR —— 只需要 EGLDisplay,
     *    **不需要 context/surface**,可在任意线程调用。
     */
    fun detectGpuIdentity(): String? =
        readGpuSystemProperty() ?: queryEglVendor()

    private fun readGpuSystemProperty(): String? = try {
        @Suppress("PrivateApi")
        val clazz = Class.forName("android.os.SystemProperties")
        val get = clazz.getMethod("get", String::class.java)
        val egl = get.invoke(null, "ro.hardware.egl") as? String
        val value = if (!egl.isNullOrBlank()) egl else Build.HARDWARE
        value?.takeIf { it.isNotBlank() }
    } catch (e: Throwable) {
        // hidden API 被拦截时退回 Build.HARDWARE(公开 API)
        Build.HARDWARE?.takeIf { it.isNotBlank() }
    }

    private fun queryEglVendor(): String? = try {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) {
            null
        } else {
            // eglQueryString 允许在未 initialize 的 display 上查 EGL_VENDOR,
            // 失败时返回 null,不抛异常
            EGL14.eglQueryString(display, EGL14.EGL_VENDOR)
                ?.takeIf { it.isNotBlank() }
        }
    } catch (e: Throwable) {
        Log.w(TAG, "查询 EGL_VENDOR 失败: ${e.message}")
        null
    }
}
