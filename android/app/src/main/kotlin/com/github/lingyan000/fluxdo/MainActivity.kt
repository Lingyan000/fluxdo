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
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager as WebCookieManager
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
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

    private val CHANNEL = "com.github.lingyan000.fluxdo/browser"
    private val CRASHLYTICS_CHANNEL = "com.github.lingyan000.fluxdo/crashlytics"
    private val ICON_CHANNEL = "com.github.lingyan000.fluxdo/app_icon"
    private val ioExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        try {
                            val cookieManager = WebCookieManager.getInstance()
                            cookieManager.setCookie(url, rawSetCookie) { success ->
                                cookieManager.flush()
                                result.success(success)
                            }
                        } catch (e: Exception) {
                            Log.e("RawCookie", "setCookie failed: ${e.message}", e)
                            result.success(false)
                        }
                    } else {
                        result.error("INVALID_ARGS", "url and rawSetCookie required", null)
                    }
                }

                // 暴力穷举删除指定 name 的所有变体
                // 依据 §3.3.2: Android 删除变体必须 Domain 属性精确匹配
                // 依据 §3.3.3: Android 无法精确枚举变体, 只能穷举候选组合
                "nukeAllVariants" -> {
                    val url = call.argument<String>("url")
                    val name = call.argument<String>("name")
                    val domainCandidates = call.argument<List<String?>>("domainCandidates")
                    val pathCandidates = call.argument<List<String>>("pathCandidates")
                    if (url != null && name != null && domainCandidates != null && pathCandidates != null) {
                        ioExecutor.execute {
                            try {
                                val mgr = WebCookieManager.getInstance()
                                val combinations = mutableListOf<Pair<String?, String>>()
                                for (domain in domainCandidates) {
                                    for (path in pathCandidates) {
                                        combinations.add(Pair(domain, path))
                                    }
                                }
                                val latch = CountDownLatch(combinations.size)
                                val deletedCount = AtomicInteger(0)
                                for ((domain, path) in combinations) {
                                    val attrs = mutableListOf("$name=", "Max-Age=0", "Path=$path")
                                    if (domain != null) attrs.add("Domain=$domain")
                                    val rawCookie = attrs.joinToString("; ")
                                    mgr.setCookie(url, rawCookie) { success ->
                                        if (success == true) deletedCount.incrementAndGet()
                                        latch.countDown()
                                    }
                                }
                                latch.await(2, TimeUnit.SECONDS)
                                mgr.flush()
                                result.success(deletedCount.get())
                            } catch (e: Exception) {
                                Log.e("RawCookie", "nukeAllVariants failed: ${e.message}", e)
                                result.success(0)
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
                        try {
                            val mgr = WebCookieManager.getInstance()
                            val attrs = mutableListOf("$name=", "Max-Age=0", "Path=$path")
                            if (domain != null) attrs.add("Domain=$domain")
                            val rawCookie = attrs.joinToString("; ")
                            mgr.setCookie(url, rawCookie) { success ->
                                mgr.flush()
                                result.success(success ?: false)
                            }
                        } catch (e: Exception) {
                            Log.e("RawCookie", "deleteExactCookie failed: ${e.message}", e)
                            result.success(false)
                        }
                    } else {
                        result.error("INVALID_ARGS", "url, name, path required", null)
                    }
                }

                // 读取指定 url 下所有 cookie 的完整信息
                // 依据 §3.3.3: Android 旧 API 仅能拿到 name + value
                //               domain/path/secure/httpOnly/expires 字段返回 null
                //               (不依赖 GET_COOKIE_INFO, 按 §3.4 用户决策)
                "getAllCookieInfos" -> {
                    val url = call.argument<String>("url")
                    if (url != null) {
                        try {
                            val mgr = WebCookieManager.getInstance()
                            val cookieString = mgr.getCookie(url) ?: ""
                            val infos = cookieString.split(";").mapNotNull { entry ->
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
                                )
                            }
                            result.success(infos)
                        } catch (e: Exception) {
                            Log.e("RawCookie", "getAllCookieInfos failed: ${e.message}", e)
                            result.success(emptyList<Map<String, Any?>>())
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
                        try {
                            val mgr = WebCookieManager.getInstance()
                            val cookieString = mgr.getCookie(url) ?: ""
                            val count = cookieString.split(";").count { entry ->
                                val trimmed = entry.trim()
                                val eqIdx = trimmed.indexOf('=')
                                if (eqIdx <= 0) false
                                else trimmed.substring(0, eqIdx).trim() == name
                            }
                            result.success(count)
                        } catch (e: Exception) {
                            Log.e("RawCookie", "countCookiesByName failed: ${e.message}", e)
                            result.success(0)
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
