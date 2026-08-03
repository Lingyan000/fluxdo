package com.github.lingyan000.fluxdo

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager as WebCookieManager
import android.webkit.WebView
import androidx.webkit.CookieManagerCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "AppLink"
        private const val RAW_COOKIE_CHANNEL = "com.fluxdo/raw_cookie"
        private const val WEBAUTHN_CHANNEL = "com.fluxdo/webauthn"
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // 强制重新分发 WindowInsets，修复 Android 15 旋转后 FlutterView 高度不更新的问题
        window.decorView.requestApplyInsets()
    }

    // 修复 Android 14+ 预见式返回手势进行中时, 锁屏 / 切后台导致 UI 卡死
    // 根因: 系统不会在 Activity 进入 stopped 时补发 onBackCancelled, Flutter 引擎
    //       不知道手势已中断, Dart 路由 AnimationController 卡在 0.x 中间值,
    //       回前台后整个 UI 无响应 (参见 flutter/flutter#161040 / #105561)
    // 方案: stop 前主动广播 cancelBackGesture, Dart 端 reverse 复位
    //       手势未进行时调用也安全, 引擎会忽略
    override fun onStop() {
        try {
            flutterEngine?.backGestureChannel?.cancelBackGesture()
        } catch (e: Throwable) {
            Log.w(TAG, "cancelBackGesture on stop failed: ${e.message}")
        }
        super.onStop()
    }

    private val CHANNEL = "com.github.lingyan000.fluxdo/browser"
    private val CRASHLYTICS_CHANNEL = "com.github.lingyan000.fluxdo/crashlytics"
    private val ICON_CHANNEL = "com.github.lingyan000.fluxdo/app_icon"
    private val mainHandler = Handler(Looper.getMainLooper())

    // Cookie IPC 专用后台线程。CookieManager 的 getCookie / setCookie /
    // getCookieInfo 可从任意线程调用(Chromium cookie store 在自己的 IO
    // 线程上工作,调用线程只是发起+等待),setCookie 的 ValueCallback 只要求
    // 发起线程带 Looper — HandlerThread 两者都满足(React Native
    // ForwardingCookieHandler 同款设计,flutter_inappwebview 的注释也确认
    // "done on a background thread as needed")。
    //
    // 此前整段跑在平台主线程:cf_clearance 周期轮询 / priming 逐 cookie
    // 三段式 / sweep 的每一次 getCookie/setCookie 都在挤 vsync 分发,
    // 撞上滚动帧即 vsyncOverhead 型掉帧。下沉后平台主线程零 cookie 工作。
    private var cookieThread: HandlerThread? = null
    private var cookieHandler: Handler? = null

    @Synchronized
    private fun onCookieThread(block: () -> Unit) {
        val handler = cookieHandler ?: run {
            val thread = HandlerThread("fluxdo-cookie").also { it.start() }
            cookieThread = thread
            Handler(thread.looper).also { cookieHandler = it }
        }
        handler.post(block)
    }

    override fun onDestroy() {
        cookieThread?.quitSafely()
        cookieThread = null
        cookieHandler = null
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        FairMemoryReceiver.detachEngine(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 公平内存预警 → Dart 标准 memoryPressure 的转发依赖 engine 引用
        FairMemoryReceiver.attachEngine(flutterEngine)
        // 媒体转码通道(音视频压缩到 4MB:media3 Transformer 硬编)
        MediaTranscodeChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openInBrowser" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        val success = openInExternalBrowser(url)
                        result.success(success)
                    } else {
                        result.error("INVALID_URL", "URL is null", null)
                    }
                }
                "resolveAppLink" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        result.success(resolveAppLink(url))
                    } else {
                        result.error("INVALID_URL", "URL is null", null)
                    }
                }
                "launchAppLink" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        result.success(launchAppLink(url))
                    } else {
                        result.error("INVALID_URL", "URL is null", null)
                    }
                }
                // 展示登录二维码期间置 FLAG_SECURE:防截屏/录屏/最近任务缩略图
                "setSecureScreen" -> {
                    val secure = call.argument<Boolean>("secure") ?: false
                    runOnUiThread {
                        if (secure) {
                            window.setFlags(
                                WindowManager.LayoutParams.FLAG_SECURE,
                                WindowManager.LayoutParams.FLAG_SECURE,
                            )
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CRASHLYTICS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setCrashlyticsEnabled" -> {
                    val enable = call.argument<Boolean>("enabled") ?: false
                    FluxdoApplication.setCrashlytics(enable)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ICON_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setAlternateIcon" -> {
                    val iconName = call.argument<String?>("iconName")
                    try {
                        setAlternateIcon(iconName)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("AppIcon", "切换图标失败: ${e.message}", e)
                        result.error("ICON_CHANGE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Raw Set-Cookie 写入通道
        // 直接传原始 Set-Cookie 头给 Android CookieManager，保留 host-only 等完整语义
        // v0.4.0 扩展: 增加 nukeAllVariants / deleteExactCookie / getAllCookieInfos
        //              / countCookiesByName 用于 Sentinel 内核
        //              (设计依据: docs/cookie-sync-design-v0.4.0.md §5.4)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RAW_COOKIE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setRawCookie" -> {
                    val url = call.argument<String>("url")
                    val rawSetCookie = call.argument<String>("rawSetCookie")
                    if (url != null && rawSetCookie != null) {
                        onCookieThread {
                            try {
                                val cookieManager = WebCookieManager.getInstance()
                                cookieManager.setCookie(url, rawSetCookie) { success ->
                                    cookieManager.flush()
                                    mainHandler.post { result.success(success) }
                                }
                            } catch (e: Exception) {
                                Log.e("RawCookie", "setCookie failed: ${e.message}", e)
                                mainHandler.post { result.success(false) }
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "url and rawSetCookie required", null)
                    }
                }

                // 暴力穷举删除指定 name 的所有变体
                // 依据 §3.3.2: Android 删除变体必须 Domain 属性精确匹配
                // 依据 §3.3.3: Android 无法精确枚举变体, 只能穷举候选组合
                //
                // 注意: CookieManager.setCookie(url, value, ValueCallback) 必须在
                // 带 Looper 的线程上调用 (否则抛 IllegalStateException), 因此整段
                // 调度 post 到 cookie HandlerThread (带 Looper 且不占平台主线程);
                // 同时用 AtomicInteger 计数代替 CountDownLatch, 避免 await 阻塞。
                "nukeAllVariants" -> {
                    val url = call.argument<String>("url")
                    val name = call.argument<String>("name")
                    val domainCandidates = call.argument<List<String?>>("domainCandidates")
                    val pathCandidates = call.argument<List<String>>("pathCandidates")
                    if (url != null && name != null && domainCandidates != null && pathCandidates != null) {
                        onCookieThread {
                            try {
                                val mgr = WebCookieManager.getInstance()
                                // 优先：GET_COOKIE_INFO 拿每条 cookie 的真实 domain/path 精确删，
                                // 与 countCookiesByName(getCookie) 对齐，杜绝"数得到删不掉"的残留循环。
                                // 旧 WebView(<105) 不支持时回退到穷举候选组合。
                                val targets = linkedSetOf<Pair<String?, String>>()
                                fun addDomainVariants(rawDomain: String?, path: String) {
                                    targets.add(Pair(null, path))
                                    val trimmed = rawDomain?.trim()
                                    if (!trimmed.isNullOrEmpty()) {
                                        val bare = trimmed.removePrefix(".")
                                        targets.add(Pair(trimmed, path))
                                        targets.add(Pair(bare, path))
                                        targets.add(Pair(".$bare", path))
                                    }
                                }
                                if (WebViewFeature.isFeatureSupported(WebViewFeature.GET_COOKIE_INFO)) {
                                    for (line in CookieManagerCompat.getCookieInfo(mgr, url)) {
                                        val params = line.split(";")
                                        if (params.isEmpty()) continue
                                        val nv = params[0].split("=", limit = 2)
                                        if (nv[0].trim() != name) continue
                                        var domain: String? = null
                                        var path = "/"
                                        for (i in 1 until params.size) {
                                            val kv = params[i].split("=", limit = 2)
                                            val k = kv[0].trim()
                                            val v = if (kv.size > 1) kv[1].trim() else ""
                                            if (k.equals("Domain", ignoreCase = true)) {
                                                domain = v
                                            } else if (k.equals("Path", ignoreCase = true) && v.isNotEmpty()) {
                                                path = v
                                            }
                                        }
                                        addDomainVariants(domain, path)
                                    }
                                }
                                for (domain in domainCandidates) {
                                    for (path in pathCandidates) {
                                        addDomainVariants(domain, path)
                                    }
                                }
                                if (targets.isEmpty()) {
                                    mainHandler.post { result.success(0) }
                                    return@onCookieThread
                                }
                                // 删除写入的属性变体:覆盖 普通 / Secure / Secure;SameSite=None
                                // / Secure;SameSite=None;Partitioned。
                                // 仅带 Path/Domain 无法覆盖 cf_clearance 这种
                                // SameSite=None;Secure 的 cookie(覆盖判定不匹配 → 删不掉)。
                                // Partitioned(CHIPS) 副本存在独立分区 jar,删除头必须同带
                                // Secure+Partitioned 才能命中(Chromium 按 host key +
                                // partition key 匹配);App 内 WebView 顶级站点即 cookie
                                // 本域,分区键就是自身,故此删除头恰好落在正确分区。
                                fun deleteRawVariants(domain: String?, path: String): List<String> {
                                    val base = mutableListOf(
                                        "$name=",
                                        "Max-Age=0",
                                        "Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                                        "Path=$path"
                                    )
                                    if (domain != null) base.add("Domain=$domain")
                                    val plain = base.joinToString("; ")
                                    return listOf(
                                        plain,
                                        "$plain; Secure",
                                        "$plain; Secure; SameSite=None",
                                        "$plain; Secure; SameSite=None; Partitioned"
                                    )
                                }
                                fun countName(): Int {
                                    val cs = mgr.getCookie(url) ?: ""
                                    return cs.split(";").count { entry ->
                                        val t = entry.trim()
                                        val i = t.indexOf('=')
                                        i > 0 && t.substring(0, i).trim() == name
                                    }
                                }
                                val deletedTotal = AtomicInteger(0)
                                // 同 (name,domain,path) 多份时,单次 setCookie 只覆盖一份,
                                // 需"删除→数→再删"多轮逐份清净,带硬上限防死循环。
                                val maxRounds = 5
                                fun runRound(round: Int, prevAfter: Int) {
                                    val raws = targets.flatMap { (domain, path) ->
                                        deleteRawVariants(domain, path)
                                    }
                                    val remaining = AtomicInteger(raws.size)
                                    for (raw in raws) {
                                        mgr.setCookie(url, raw) { success ->
                                            if (success == true) deletedTotal.incrementAndGet()
                                            if (remaining.decrementAndGet() == 0) {
                                                mgr.flush()
                                                val after = countName()
                                                Log.d(
                                                    "RawCookie",
                                                    "nukeAllVariants name=$name round=$round after=$after"
                                                )
                                                // after>0 但相比上轮没减少 → 删不动了(如 CHIPS 分区 cookie),
                                                // 提前停,别白跑剩余轮次。
                                                val stuck = round > 1 && after >= prevAfter
                                                if (after > 0 && round < maxRounds && !stuck) {
                                                    onCookieThread { runRound(round + 1, after) }
                                                } else {
                                                    mainHandler.post {
                                                        result.success(deletedTotal.get())
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                runRound(1, Int.MAX_VALUE)
                            } catch (e: Exception) {
                                Log.e("RawCookie", "nukeAllVariants failed: ${e.message}", e)
                                mainHandler.post { result.success(0) }
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "url, name, domainCandidates, pathCandidates required", null)
                    }
                }

                // 精确删除指定 (name, domain, path) 的单条 cookie 变体
                // Android 上退化为单组合 nukeAllVariants
                "deleteExactCookie" -> {
                    val url = call.argument<String>("url")
                    val name = call.argument<String>("name")
                    val domain = call.argument<String>("domain")
                    val path = call.argument<String>("path")
                    if (url != null && name != null && path != null) {
                        onCookieThread {
                            try {
                                val mgr = WebCookieManager.getInstance()
                                val base = mutableListOf(
                                    "$name=",
                                    "Max-Age=0",
                                    "Expires=Thu, 01 Jan 1970 00:00:00 GMT",
                                    "Path=$path"
                                )
                                if (domain != null) base.add("Domain=$domain")
                                val plain = base.joinToString("; ")
                                // 带全属性变体,覆盖 Secure / SameSite=None;Secure /
                                // Partitioned(CHIPS 分区副本需 Secure+Partitioned 才能命中)。
                                val raws = listOf(
                                    plain,
                                    "$plain; Secure",
                                    "$plain; Secure; SameSite=None",
                                    "$plain; Secure; SameSite=None; Partitioned"
                                )
                                val remaining = AtomicInteger(raws.size)
                                val anySuccess = java.util.concurrent.atomic.AtomicBoolean(false)
                                for (raw in raws) {
                                    mgr.setCookie(url, raw) { success ->
                                        if (success == true) anySuccess.set(true)
                                        if (remaining.decrementAndGet() == 0) {
                                            mgr.flush()
                                            mainHandler.post { result.success(anySuccess.get()) }
                                        }
                                    }
                                }
                            } catch (e: Exception) {
                                Log.e("RawCookie", "deleteExactCookie failed: ${e.message}", e)
                                mainHandler.post { result.success(false) }
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "url, name, path required", null)
                    }
                }

                // 读取指定 url 下所有 cookie 的完整信息
                // 新 WebView 通过 GET_COOKIE_INFO 拿 domain/path 等字段；
                // 旧 WebView 回退到 getCookie()，只能拿到 name + value。
                "getAllCookieInfos" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        onCookieThread {
                            try {
                                val mgr = WebCookieManager.getInstance()
                                fun parseCookieInfo(line: String): Map<String, Any?>? {
                                    val params = line.split(";")
                                    if (params.isEmpty()) return null
                                    val nv = params[0].split("=", limit = 2)
                                    val cookieName = nv[0].trim()
                                    if (cookieName.isEmpty()) return null

                                    var domain: String? = null
                                    var path: String? = null
                                    var isSecure: Boolean? = null
                                    var isHttpOnly: Boolean? = null
                                    var expiresMillis: Long? = null
                                    var sameSite: String? = null
                                    var isPartitioned: Boolean? = null

                                    fun parseExpires(value: String): Long? {
                                        val patterns = listOf(
                                            "EEE, dd MMM yyyy HH:mm:ss zzz",
                                            "EEE, dd-MMM-yyyy HH:mm:ss zzz"
                                        )
                                        for (pattern in patterns) {
                                            try {
                                                val format = java.text.SimpleDateFormat(
                                                    pattern,
                                                    java.util.Locale.US
                                                )
                                                format.timeZone = java.util.TimeZone.getTimeZone("GMT")
                                                return format.parse(value)?.time
                                            } catch (ignored: Exception) {
                                            }
                                        }
                                        return null
                                    }

                                    for (i in 1 until params.size) {
                                        val part = params[i].trim()
                                        if (part.isEmpty()) continue
                                        val kv = part.split("=", limit = 2)
                                        val key = kv[0].trim()
                                        val value = if (kv.size > 1) kv[1].trim() else ""
                                        when {
                                            key.equals("Domain", ignoreCase = true) -> domain = value
                                            key.equals("Path", ignoreCase = true) -> path = value
                                            key.equals("Secure", ignoreCase = true) -> isSecure = true
                                            key.equals("HttpOnly", ignoreCase = true) -> isHttpOnly = true
                                            key.equals("Expires", ignoreCase = true) -> expiresMillis = parseExpires(value)
                                            key.equals("SameSite", ignoreCase = true) -> sameSite = value
                                            key.equals("Partitioned", ignoreCase = true) -> isPartitioned = true
                                        }
                                    }

                                    // 诊断:cf_clearance 是否被 CF 设为 Partitioned(CHIPS)。
                                    // 只打属性,绝不打 value——cf_clearance 是有效凭证,不能进 logcat。
                                    if (cookieName == "cf_clearance") {
                                        Log.d(
                                            "RawCookie",
                                            "cf_clearance attrs: partitioned=$isPartitioned " +
                                                "secure=$isSecure samesite=$sameSite " +
                                                "domain=$domain path=$path"
                                        )
                                    }

                                    return mapOf<String, Any?>(
                                        "name" to cookieName,
                                        "value" to if (nv.size > 1) nv[1].trim() else "",
                                        "domain" to domain,
                                        "path" to path,
                                        "isSecure" to isSecure,
                                        "isHttpOnly" to isHttpOnly,
                                        "expiresMillis" to expiresMillis,
                                        "sameSite" to sameSite,
                                        "partitioned" to isPartitioned,
                                    )
                                }

                                val cookieString = mgr.getCookie(url) ?: ""
                                val infos = if (WebViewFeature.isFeatureSupported(WebViewFeature.GET_COOKIE_INFO)) {
                                    CookieManagerCompat.getCookieInfo(mgr, url).mapNotNull { line ->
                                        parseCookieInfo(line)
                                    }
                                } else {
                                    cookieString.split(";").mapNotNull { entry ->
                                        val trimmed = entry.trim()
                                        if (trimmed.isEmpty()) return@mapNotNull null
                                        val eqIdx = trimmed.indexOf('=')
                                        if (eqIdx <= 0) return@mapNotNull null
                                        val cookieName = trimmed.substring(0, eqIdx).trim()
                                        val cookieValue = trimmed.substring(eqIdx + 1).trim()
                                        mapOf<String, Any?>(
                                            "name" to cookieName,
                                            "value" to cookieValue,
                                            "domain" to null,
                                            "path" to null,
                                            "isSecure" to null,
                                            "isHttpOnly" to null,
                                            "expiresMillis" to null,
                                            "sameSite" to null,
                                        )
                                    }
                                }
                                mainHandler.post { result.success(infos) }
                            } catch (e: Exception) {
                                Log.e("RawCookie", "getAllCookieInfos failed: ${e.message}", e)
                                mainHandler.post {
                                    result.success(emptyList<Map<String, Any?>>())
                                }
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "url required", null)
                    }
                }

                // 统计指定 url 下 cookie name 的变体数
                // 基于 CookieManager.getCookie() 拼接字符串拆分计数
                "countCookiesByName" -> {
                    val url = call.argument<String>("url")
                    val name = call.argument<String>("name")
                    if (url != null && name != null) {
                        onCookieThread {
                            try {
                                val mgr = WebCookieManager.getInstance()
                                val cookieString = mgr.getCookie(url) ?: ""
                                val count = cookieString.split(";").count { entry ->
                                    val trimmed = entry.trim()
                                    val eqIdx = trimmed.indexOf('=')
                                    if (eqIdx <= 0) false
                                    else trimmed.substring(0, eqIdx).trim() == name
                                }
                                mainHandler.post { result.success(count) }
                            } catch (e: Exception) {
                                Log.e("RawCookie", "countCookiesByName failed: ${e.message}", e)
                                mainHandler.post { result.success(0) }
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "url, name required", null)
                    }
                }

                else -> result.notImplemented()
            }
        }


        // WebAuthn/PassKey 支持通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEBAUTHN_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableWebAuthentication" -> {
                    result.success(enableWebAuthenticationForAllWebViews())
                }
                else -> result.notImplemented()
            }
        }
    }

    // ======================== WebAuthn/PassKey ========================

    /**
     * 遍历 View 树找到所有 WebView 实例并启用 WebAuthn 支持。
     * 依赖 flutter_inappwebview 自带的 androidx.webkit 库。
     */
    private fun enableWebAuthenticationForAllWebViews(): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION)) {
            Log.w(TAG, "WebAuthn: 当前 WebView 版本不支持 WEB_AUTHENTICATION")
            return false
        }
        val webViews = mutableListOf<WebView>()
        findWebViews(window.decorView, webViews)
        for (wv in webViews) {
            WebSettingsCompat.setWebAuthenticationSupport(
                wv.settings,
                WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_BROWSER
            )
        }
        Log.i(TAG, "WebAuthn: 已为 ${webViews.size} 个 WebView 启用 PassKey 支持")
        return webViews.isNotEmpty()
    }

    private fun findWebViews(view: View, result: MutableList<WebView>) {
        if (view is WebView) {
            result.add(view)
        } else if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findWebViews(view.getChildAt(i), result)
            }
        }
    }

    // ======================== 动态图标切换 ========================

    /**
     * 切换应用启动器图标。
     * @param iconName activity-alias 短名（如 "ModernIcon"），null 表示恢复经典图标（DefaultIcon）
     *
     * 注意：.MainActivity 永远保持 enabled，不参与切换，
     * 避免影响 adb / Flutter 工具链的直接启动。
     */
    private fun setAlternateIcon(iconName: String?) {
        val pm = packageManager
        val pkgName = packageName

        // 目标 alias：null → 经典图标
        val targetAlias = "$pkgName.${iconName ?: "DefaultIcon"}"

        val flags = PackageManager.GET_ACTIVITIES or PackageManager.GET_DISABLED_COMPONENTS
        val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(pkgName, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(pkgName, flags)
        }

        val activities = pkgInfo.activities ?: throw IllegalStateException("No activities found")

        // 先启用目标 alias，确保 app 始终可从启动器打开
        pm.setComponentEnabledSetting(
            ComponentName(pkgName, targetAlias),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )

        // 禁用其他 alias（只操作 activity-alias，不碰 .MainActivity）
        for (info in activities) {
            if (info.targetActivity == null) continue  // 跳过主 Activity
            if (info.name == targetAlias) continue      // 跳过目标

            pm.setComponentEnabledSetting(
                ComponentName(pkgName, info.name),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
        }

        Log.d("AppIcon", "图标已切换: ${iconName ?: "DefaultIcon"}")
    }

    // ======================== 应用链接解析与启动 ========================

    /**
     * 解析应用链接，获取目标应用的名称和图标。
     * 优先级：
     *   1. intent 中自带 package → 直接通过包名查找
     *   2. queryIntentActivities (MATCH_DEFAULT_ONLY)
     *   3. queryIntentActivities (flag = 0，不限 DEFAULT)
     */
    private fun resolveAppLink(url: String): Map<String, Any?> {
        Log.d(TAG, "resolveAppLink: $url")
        try {
            val intent = parseAppLinkIntent(url)
            if (intent == null) {
                Log.w(TAG, "parseAppLinkIntent returned null")
                return mapOf("canResolve" to false)
            }

            // 路径 1: intent 自带 package 参数 → 直接查包名
            val targetPackage = intent.`package`
            if (targetPackage != null && targetPackage != packageName) {
                Log.d(TAG, "Intent has package: $targetPackage, trying direct lookup")
                val info = getAppInfoByPackage(targetPackage)
                if (info != null) return info
            }

            // 路径 2: queryIntentActivities + MATCH_DEFAULT_ONLY
            val target = findTargetActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
            if (target != null) return target

            // 路径 3: queryIntentActivities 无 flag 限制
            val targetFallback = findTargetActivity(intent, 0)
            if (targetFallback != null) return targetFallback

            Log.d(TAG, "No matching activity found")
            return mapOf("canResolve" to false)
        } catch (e: Exception) {
            Log.e(TAG, "resolveAppLink error", e)
            return mapOf("canResolve" to false)
        }
    }

    /** 通过包名直接获取应用信息 */
    private fun getAppInfoByPackage(pkgName: String): Map<String, Any?>? {
        return try {
            val appInfo = getAppInfo(pkgName)
            val appName = packageManager.getApplicationLabel(appInfo).toString()
            val iconBytes = drawableToBytes(packageManager.getApplicationIcon(appInfo))
            Log.d(TAG, "Direct lookup success: $appName ($pkgName), icon ${iconBytes.size} bytes")
            mapOf(
                "canResolve" to true,
                "appName" to appName,
                "packageName" to pkgName,
                "appIcon" to iconBytes
            )
        } catch (e: PackageManager.NameNotFoundException) {
            Log.d(TAG, "Package not found: $pkgName")
            null
        } catch (e: Exception) {
            Log.w(TAG, "getAppInfoByPackage error for $pkgName", e)
            null
        }
    }

    /** 通过 queryIntentActivities 查找目标 Activity 并获取应用信息 */
    private fun findTargetActivity(intent: Intent, flags: Int): Map<String, Any?>? {
        val activities: List<ResolveInfo> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(flags.toLong())
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(intent, flags)
        }

        Log.d(TAG, "queryIntentActivities (flags=$flags): ${activities.size} results → " +
            activities.joinToString { it.activityInfo.packageName })

        val target = activities.firstOrNull {
            it.activityInfo.packageName != packageName &&
            it.activityInfo.packageName != "android"
        } ?: return null

        return getAppInfoByPackage(target.activityInfo.packageName)
    }

    /**
     * 启动应用链接。
     * 支持 intent:// URL，并在失败时尝试 fallback URL 或 Play 商店。
     */
    private fun launchAppLink(url: String): Boolean {
        try {
            val intent = parseAppLinkIntent(url) ?: return false
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            return true
        } catch (e: ActivityNotFoundException) {
            // intent:// URL 启动失败，尝试 fallback
            if (url.startsWith("intent://") || url.startsWith("intent:")) {
                return handleIntentFallback(url)
            }
            return false
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    /** 解析 URL 为 Intent */
    private fun parseAppLinkIntent(url: String): Intent? {
        return try {
            if (url.startsWith("intent://") || url.startsWith("intent:")) {
                Intent.parseUri(url, Intent.URI_INTENT_SCHEME)
            } else {
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
            }
        } catch (e: Exception) {
            Log.w(TAG, "parseAppLinkIntent failed for $url", e)
            null
        }
    }

    /** 获取 ApplicationInfo（兼容 API 33+） */
    private fun getAppInfo(packageName: String): android.content.pm.ApplicationInfo {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            this.packageManager.getApplicationInfo(
                packageName,
                PackageManager.ApplicationInfoFlags.of(0)
            )
        } else {
            @Suppress("DEPRECATION")
            this.packageManager.getApplicationInfo(packageName, 0)
        }
    }

    /** 将 Drawable 转为 PNG 字节数组 */
    private fun drawableToBytes(drawable: Drawable): ByteArray {
        // 用 drawable 自身尺寸，但限制在合理范围
        val w = drawable.intrinsicWidth.coerceIn(1, 256)
        val h = drawable.intrinsicHeight.coerceIn(1, 256)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, w, h)
        drawable.draw(canvas)

        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        val bytes = stream.toByteArray()
        bitmap.recycle()
        return bytes
    }

    /** 处理 intent:// 的 fallback：browser_fallback_url → Play 商店 */
    private fun handleIntentFallback(url: String): Boolean {
        try {
            val parsed = Intent.parseUri(url, Intent.URI_INTENT_SCHEME)

            // 1. 尝试 fallback URL
            val fallbackUrl = parsed.getStringExtra("browser_fallback_url")
            if (fallbackUrl != null) {
                val fallbackIntent = Intent(Intent.ACTION_VIEW, Uri.parse(fallbackUrl))
                fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(fallbackIntent)
                return true
            }

            // 2. 尝试 Play 商店
            val pkg = parsed.`package`
            if (pkg != null) {
                val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg"))
                marketIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(marketIntent)
                return true
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return false
    }

    // ======================== 外部浏览器 ========================

    private fun openInExternalBrowser(url: String): Boolean {
        return try {
            // 使用一个通用的 HTTPS URL 来查询默认浏览器
            val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com"))
            browserIntent.addCategory(Intent.CATEGORY_BROWSABLE)

            // 获取默认浏览器
            val defaultBrowser: ResolveInfo? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.resolveActivity(
                    browserIntent,
                    PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong())
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.resolveActivity(browserIntent, PackageManager.MATCH_DEFAULT_ONLY)
            }

            val targetIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            targetIntent.addCategory(Intent.CATEGORY_BROWSABLE)
            targetIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK

            if (defaultBrowser != null && defaultBrowser.activityInfo.packageName != packageName) {
                // 使用默认浏览器打开
                targetIntent.setPackage(defaultBrowser.activityInfo.packageName)
                startActivity(targetIntent)
                true
            } else {
                // 默认浏览器是自己或未找到，查找其他浏览器
                val resolveInfoList: List<ResolveInfo> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.queryIntentActivities(
                        browserIntent,
                        PackageManager.ResolveInfoFlags.of(0)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.queryIntentActivities(browserIntent, 0)
                }

                val otherBrowsers = resolveInfoList.filter {
                    it.activityInfo.packageName != packageName
                }

                if (otherBrowsers.isNotEmpty()) {
                    // 使用第一个可用的浏览器
                    targetIntent.setPackage(otherBrowsers[0].activityInfo.packageName)
                    startActivity(targetIntent)
                    true
                } else {
                    // 没有其他浏览器，无法打开
                    false
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
