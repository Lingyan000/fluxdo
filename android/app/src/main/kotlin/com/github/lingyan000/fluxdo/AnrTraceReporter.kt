package com.github.lingyan000.fluxdo

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * 上次进程退出原因上报(ANR 现场取证)。
 *
 * 背景:Crashlytics 的 ANR 事件只回传 main 线程栈,`... frames omitted ...`
 * 之后的其他线程一概拿不到。而 `nativeSurfaceChanged` 型 ANR 的主线程只是
 * 在 futex 上等 Flutter 引擎回话 —— **真正占着锁的是引擎线程**,恰恰在被
 * 省略的那部分里。没有它就只能猜。
 *
 * [ActivityManager.getHistoricalProcessExitReasons] 给的是系统侧完整记录:
 * REASON_ANR 的 traceInputStream 里含**全部线程**栈(含 1.ui / 1.raster),
 * 同时还能区分 ANR / native crash / LMK 内存杀 —— 这三者在应用自身日志里
 * 长得一模一样(进程都是直接消失,不留遗言)。
 *
 * 仅 Android 11 (API 30)+ 可用;更低版本静默跳过(该 API 不存在)。
 * 当前受影响用户 100% 落在 API 30~33,覆盖完整。
 */
object AnrTraceReporter {

    private const val TAG = "AnrTrace"

    /** trace 全文按此长度分片写入 Crashlytics log(单条 log 有长度上限)。 */
    private const val CHUNK_SIZE = 4000

    /** 单次最多上报几条历史退出记录(系统最多保留 16 条)。 */
    private const val MAX_RECORDS = 5

    /** trace 最多上报多少字符,防止超大 dump 把配额吃光。 */
    private const val MAX_TRACE_CHARS = 60_000

    /** 已上报过的退出记录时间戳,避免每次启动重复上报同一条。 */
    private const val PREFS_NAME = "anr_trace_reporter"
    private const val KEY_LAST_REPORTED_AT = "last_reported_timestamp"

    /**
     * 检查并上报上次进程的异常退出现场。
     *
     * 必须在 Crashlytics 已启用后调用 —— 未启用时直接返回,不做任何事,
     * 保持"用户没开就零网络请求"的既有语义。
     */
    fun reportIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        if (FirebaseApp.getApps(context).isEmpty()) return

        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
            val records = am.getHistoricalProcessExitReasons(context.packageName, 0, MAX_RECORDS)
            if (records.isEmpty()) return

            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val lastReportedAt = prefs.getLong(KEY_LAST_REPORTED_AT, 0L)
            var newestSeen = lastReportedAt

            // 系统返回按时间倒序;反过来按时间正序上报,保证 Crashlytics 里的顺序自然。
            for (info in records.reversed()) {
                if (info.timestamp <= lastReportedAt) continue
                if (info.timestamp > newestSeen) newestSeen = info.timestamp
                if (!isInteresting(info.reason)) continue
                report(info)
            }

            if (newestSeen > lastReportedAt) {
                prefs.edit().putLong(KEY_LAST_REPORTED_AT, newestSeen).apply()
            }
        } catch (e: Throwable) {
            // 取证功能本身绝不能影响启动
            Log.w(TAG, "上报上次退出原因失败: ${e.message}")
        }
    }

    /**
     * 只上报"非正常退出"。用户主动划掉 / 系统常规回收不值得占配额。
     */
    private fun isInteresting(reason: Int): Boolean = when (reason) {
        ApplicationExitInfo.REASON_ANR,
        ApplicationExitInfo.REASON_CRASH,
        ApplicationExitInfo.REASON_CRASH_NATIVE,
        ApplicationExitInfo.REASON_LOW_MEMORY,
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
        ApplicationExitInfo.REASON_SIGNALED -> true
        else -> false
    }

    private fun report(info: ApplicationExitInfo) {
        val crashlytics = FirebaseCrashlytics.getInstance()
        val reasonName = reasonName(info.reason)

        crashlytics.setCustomKey("exit_reason", reasonName)
        crashlytics.setCustomKey("exit_timestamp", info.timestamp)
        crashlytics.setCustomKey("exit_importance", importanceName(info.importance))
        crashlytics.setCustomKey("exit_description", info.description ?: "-")
        crashlytics.setCustomKey("exit_pss_kb", info.pss)
        crashlytics.setCustomKey("exit_rss_kb", info.rss)

        crashlytics.log(
            "[ExitInfo] reason=$reasonName importance=${importanceName(info.importance)} " +
                "ts=${info.timestamp} pss=${info.pss}KB rss=${info.rss}KB desc=${info.description}"
        )

        // ANR 的 traceInputStream 才是重点:含全部线程栈。
        // 其他退出原因通常没有 trace(native crash 的 tombstone 需要额外权限)。
        val trace = readTrace(info)
        if (trace.isNullOrBlank()) {
            crashlytics.log("[ExitInfo] 无 trace 数据")
        } else {
            val clipped = if (trace.length > MAX_TRACE_CHARS) {
                trace.substring(0, MAX_TRACE_CHARS) + "\n...[truncated ${trace.length - MAX_TRACE_CHARS} chars]"
            } else {
                trace
            }
            crashlytics.setCustomKey("exit_trace_chars", trace.length)
            logInChunks(crashlytics, clipped)
        }

        // 用一条非致命异常把这次现场"钉"成 Crashlytics 里的独立 issue,
        // 否则 log/customKey 只会挂在下一次真实崩溃上,平时根本看不到。
        crashlytics.recordException(
            PreviousExitException("上次进程异常退出: $reasonName (${info.description ?: "no desc"})")
        )
        Log.i(TAG, "已上报上次退出: $reasonName")
    }

    private fun readTrace(info: ApplicationExitInfo): String? = try {
        info.traceInputStream?.bufferedReader()?.use { it.readText() }
    } catch (e: Throwable) {
        Log.w(TAG, "读取 trace 失败: ${e.message}")
        null
    }

    /**
     * Crashlytics 单条 log 有长度上限,超长会被截断。按块写入保证 trace 完整。
     */
    private fun logInChunks(crashlytics: FirebaseCrashlytics, text: String) {
        var index = 0
        var part = 0
        while (index < text.length) {
            val end = minOf(index + CHUNK_SIZE, text.length)
            crashlytics.log("[ANRTrace#$part] ${text.substring(index, end)}")
            index = end
            part++
        }
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_CRASH -> "CRASH_JVM"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INIT_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        else -> "UNKNOWN($reason)"
    }

    /**
     * 退出瞬间进程处于前台还是后台 —— 区分"用着用着卡死"和"后台被清理"的关键。
     */
    private fun importanceName(importance: Int): String = when (importance) {
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "FOREGROUND"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE -> "FOREGROUND_SERVICE"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "VISIBLE"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "PERCEPTIBLE"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "SERVICE"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "CACHED"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "GONE"
        else -> "IMPORTANCE($importance)"
    }

    /** 仅用于在 Crashlytics 里生成可检索的独立 issue,不会抛到调用方。 */
    private class PreviousExitException(message: String) : Exception(message)
}
