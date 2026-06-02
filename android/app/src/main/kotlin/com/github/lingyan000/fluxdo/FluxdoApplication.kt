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
            } else {
                // Firebase 已初始化时才操作，未初始化则无需处理
                if (FirebaseApp.getApps(app).isNotEmpty()) {
                    FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(false)
                }
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
        // 不在此处初始化 Firebase，等待用户主动开启
    }
}
