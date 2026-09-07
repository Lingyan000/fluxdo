package com.github.lingyan000.fluxdo

import android.app.Application
import android.util.Log
import android.webkit.WebView
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics

class FluxdoApplication : Application() {

    companion object {
        private var appInstance: FluxdoApplication? = null

        /**
         * 设置 Crashlytics 开关。
         * 首次开启时才初始化 Firebase，避免未开启时产生任何网络请求。
         */
        fun setCrashlytics(enable: Boolean) {
            val app = appInstance ?: return
            if (enable) {
                // 延迟初始化：只在用户主动开启时初始化 Firebase
                if (FirebaseApp.getApps(app).isEmpty()) {
                    FirebaseApp.initializeApp(app)
                }
                FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)
                // Crashlytics 就绪后立刻捞上次进程的异常退出现场(ANR 全线程栈)。
                // 放在这里而非 onCreate:未开启采集时不初始化 Firebase,也就无处上报。
                AnrTraceReporter.reportIfNeeded(app)
            } else {
                // Firebase 已初始化时才操作，未初始化则无需处理
                if (FirebaseApp.getApps(app).isNotEmpty()) {
                    FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(false)
                }
            }
        }

        /**
         * 写入当前页面上下文，随崩溃 / ANR 一同上报。
         *
         * 未启用采集时 Firebase 未初始化，直接返回 —— 保持“没开就零网络请求”的既有语义。
         */
        fun setCrashContext(route: String?, routeTrail: String?) {
            val app = appInstance ?: return
            if (FirebaseApp.getApps(app).isEmpty()) return
            try {
                val crashlytics = FirebaseCrashlytics.getInstance()
                route?.let { crashlytics.setCustomKey("route", it) }
                routeTrail?.let { crashlytics.setCustomKey("route_trail", it) }
            } catch (e: Throwable) {
                Log.w("CrashContext", "写入页面上下文失败: ${e.message}")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        appInstance = this
        try {
            WebView.setWebContentsDebuggingEnabled(false)
            Log.i("WebViewDebug", "WebView debugging disabled in Application.onCreate")
        } catch (e: Throwable) {
            Log.e("WebViewDebug", "Failed to disable WebView debugging early: ${e.message}", e)
        }
        // 金标联盟公平运行内存机制:进程级注册 TRIM 广播接收器
        // (非联盟 ROM 收不到该广播,注册零成本)
        FairMemoryReceiver.initialize(this)
        // 不在此处初始化 Firebase，等待用户主动开启
    }
}
