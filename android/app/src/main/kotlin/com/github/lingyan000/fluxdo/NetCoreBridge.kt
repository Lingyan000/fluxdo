package com.github.lingyan000.fluxdo

import android.content.Context
import android.util.Log

/**
 * 把 Application Context 交给网络核心（libfluxdo_net.so）。
 *
 * 核心的证书校验走系统 TrustManager（遵循 network_security_config、信任用户安装的 CA），
 * 要经 JNI 调用 Java。核心本身由 Dart 直接 dlopen 加载，拿不到 JavaVM 与 Context，
 * 所以在 Application.onCreate 里先加载一次库并交接——早于 Flutter 引擎启动，
 * Dart 发出第一个请求时核心已经就绪。
 */
object NetCoreBridge {
    private const val TAG = "NetCoreBridge"

    fun initialize(context: Context) {
        try {
            System.loadLibrary("fluxdo_net")
            nativeInit(context.applicationContext)
        } catch (e: Throwable) {
            // 交接失败时核心的 HTTPS 无法校验证书，Dart 侧会判定核心不可用并走应急路径
            Log.e(TAG, "网络核心初始化失败: ${e.message}", e)
        }
    }

    @JvmStatic
    private external fun nativeInit(context: Context)
}
