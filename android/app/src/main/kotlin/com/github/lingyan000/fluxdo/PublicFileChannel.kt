package com.github.lingyan000.fluxdo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 公共文件落盘通道(Android 腿),与 Dart 侧 PublicFileChannel 协议对应。
 *
 * - saveToDownloads: MediaStore.Downloads 静默写入公共「下载」目录
 *   (API 29+,零权限、卸载不删);API 28 及以下返回 null,由 Dart 侧回退到
 *   应用私有下载目录(不为极少数老机型引入 WRITE_EXTERNAL_STORAGE)。
 * - saveAs: SAF ACTION_CREATE_DOCUMENT 让用户自选位置,成功后持久化 uri
 *   授权,保证「导出历史」在进程重启后仍能打开该文件。
 * - openUri: 以 ACTION_VIEW 打开上面两者返回的 content uri。
 *
 * 均返回 `{uri, displayName}`:uri 用于后续打开,displayName 用于提示文案。
 */
object PublicFileChannel {
    private const val CHANNEL = "com.fluxdo/public_file"
    private const val TAG = "PublicFile"

    /** SAF 建档请求码,避开插件常用的低位段。 */
    const val REQUEST_CREATE_DOCUMENT = 0x5AF1

    private val mainHandler = Handler(Looper.getMainLooper())

    private var activityRef: Activity? = null

    /** 等待 SAF 回调的一次性上下文(同一时刻只允许一个建档流程)。 */
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        activityRef = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> saveToDownloads(call.args(), result)
                "saveAs" -> saveAs(call.args(), result)
                "openUri" -> openUri(call.args(), result)
                "shareUri" -> shareUri(call.args(), result)
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun MethodCall.args(): Map<String, Any?> =
        (arguments as? Map<String, Any?>) ?: emptyMap()

    // ---------------------------------------------------------------- MediaStore

    private fun saveToDownloads(args: Map<String, Any?>, result: MethodChannel.Result) {
        val sourcePath = args["sourcePath"] as? String
        val fileName = args["fileName"] as? String
        if (sourcePath == null || fileName == null) {
            result.error("INVALID_ARGS", "sourcePath / fileName is null", null)
            return
        }
        // MediaStore.Downloads 集合从 Android 10 起才有,更早版本交给 Dart 回退
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(null)
            return
        }
        val activity = activityRef
        if (activity == null) {
            result.error("NO_ACTIVITY", "activity is null", null)
            return
        }

        Thread {
            var reply: Any? = null
            var error: String? = null
            val resolver = activity.contentResolver
            var target: Uri? = null
            try {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    // MIME 只在系统能从扩展名推断出同一结果时才写:传一个系统不认的
                    // 类型(如 text/markdown)会让 MediaStore 追加它认为正确的扩展名,
                    // 把 xxx.md 变成 xxx.md.txt。
                    inferredMimeType(fileName)?.let {
                        put(MediaStore.MediaColumns.MIME_TYPE, it)
                    }
                    // 写入期间对其它应用不可见,避免半成品被扫描/打开
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val collection =
                    MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                target = resolver.insert(collection, values)
                    ?: throw IllegalStateException("insert returned null")

                resolver.openOutputStream(target)?.use { out ->
                    File(sourcePath).inputStream().use { it.copyTo(out) }
                } ?: throw IllegalStateException("openOutputStream returned null")

                resolver.update(
                    target,
                    ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                    null,
                    null,
                )
                // 同名时 MediaStore 会自动改成 "xxx (1).md",回读真实名用于提示
                reply = mapOf(
                    "uri" to target.toString(),
                    "displayName" to (queryDisplayName(activity, target) ?: fileName),
                )
            } catch (e: Throwable) {
                Log.w(TAG, "saveToDownloads failed: ${e.message}")
                error = e.message ?: e.javaClass.simpleName
                target?.let { runCatching { resolver.delete(it, null, null) } }
            }
            val payload = reply
            val failure = error
            mainHandler.post {
                if (payload != null) {
                    result.success(payload)
                } else {
                    result.error("SAVE_FAILED", failure, null)
                }
            }
        }.start()
    }

    /**
     * 扩展名能被系统 MIME 表认出时返回对应类型,否则返回 null(不写 MIME_TYPE,
     * 让 MediaStore 保留原文件名)。
     */
    private fun inferredMimeType(fileName: String): String? {
        val ext = fileName.substringAfterLast('.', "")
        if (ext.isEmpty()) return null
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase())
    }

    private fun queryDisplayName(activity: Activity, uri: Uri): String? {
        return runCatching {
            activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
    }

    // ---------------------------------------------------------------------- SAF

    private fun saveAs(args: Map<String, Any?>, result: MethodChannel.Result) {
        val sourcePath = args["sourcePath"] as? String
        val fileName = args["fileName"] as? String
        if (sourcePath == null || fileName == null) {
            result.error("INVALID_ARGS", "sourcePath / fileName is null", null)
            return
        }
        val activity = activityRef
        if (activity == null) {
            result.error("NO_ACTIVITY", "activity is null", null)
            return
        }
        if (pendingResult != null) {
            result.error("BUSY", "another save-as is in progress", null)
            return
        }

        pendingResult = result
        pendingSourcePath = sourcePath
        // 建档 Intent 的 type 决定系统建议的扩展名;系统认不出扩展名时用通用
        // 二进制流,文件名本身已带扩展名,不会丢。
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = inferredMimeType(fileName) ?: "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CREATE_DOCUMENT)
        } catch (e: ActivityNotFoundException) {
            clearPending()
            result.error("NO_PICKER", e.message, null)
        }
    }

    /** MainActivity.onActivityResult 转发进来;返回 true 表示本通道已消费。 */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CREATE_DOCUMENT) return false
        val result = pendingResult ?: return true
        val sourcePath = pendingSourcePath
        clearPending()

        val target = data?.data
        if (resultCode != Activity.RESULT_OK || target == null || sourcePath == null) {
            // 用户取消:与 Dart 侧「未保存」同一表达
            result.success(null)
            return true
        }
        val activity = activityRef
        if (activity == null) {
            result.error("NO_ACTIVITY", "activity is null", null)
            return true
        }

        Thread {
            var reply: Any? = null
            var error: String? = null
            try {
                activity.contentResolver.openOutputStream(target)?.use { out ->
                    File(sourcePath).inputStream().use { it.copyTo(out) }
                } ?: throw IllegalStateException("openOutputStream returned null")
                // 持久化授权:否则进程重启后「导出历史」再点这条就打不开了
                runCatching {
                    activity.contentResolver.takePersistableUriPermission(
                        target,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
                reply = mapOf(
                    "uri" to target.toString(),
                    "displayName" to (queryDisplayName(activity, target) ?: ""),
                )
            } catch (e: Throwable) {
                Log.w(TAG, "saveAs write failed: ${e.message}")
                error = e.message ?: e.javaClass.simpleName
            }
            val payload = reply
            val failure = error
            mainHandler.post {
                if (payload != null) {
                    result.success(payload)
                } else {
                    result.error("SAVE_FAILED", failure, null)
                }
            }
        }.start()
        return true
    }

    private fun clearPending() {
        pendingResult = null
        pendingSourcePath = null
    }

    // --------------------------------------------------------------------- open

    private fun openUri(args: Map<String, Any?>, result: MethodChannel.Result) {
        val uriString = args["uri"] as? String
        if (uriString == null) {
            result.error("INVALID_ARGS", "uri is null", null)
            return
        }
        val activity = activityRef
        if (activity == null) {
            result.error("NO_ACTIVITY", "activity is null", null)
            return
        }
        val uri = runCatching { Uri.parse(uriString) }.getOrNull()
        if (uri == null) {
            result.success(false)
            return
        }
        val mime = args["mimeType"] as? String
            ?: activity.contentResolver.getType(uri)
            ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            // content uri 必须显式授权,否则接收方读不到
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "openUri: no handler for $mime")
            result.success(false)
        }
    }

    /// 把 content uri 交给系统分享面板。
    ///
    /// share_plus 只能分享文件路径，落在公共目录/SAF 的产物只有 uri，
    /// 分享这类内容必须走 ACTION_SEND + EXTRA_STREAM。
    private fun shareUri(args: Map<String, Any?>, result: MethodChannel.Result) {
        val uriString = args["uri"] as? String
        if (uriString == null) {
            result.error("INVALID_ARGS", "uri is null", null)
            return
        }
        val activity = activityRef
        if (activity == null) {
            result.error("NO_ACTIVITY", "activity is null", null)
            return
        }
        val uri = runCatching { Uri.parse(uriString) }.getOrNull()
        if (uri == null) {
            result.success(false)
            return
        }
        val mime = args["mimeType"] as? String
            ?: activity.contentResolver.getType(uri)
            ?: "*/*"
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivity(Intent.createChooser(send, null))
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "shareUri: no handler for $mime")
            result.success(false)
        }
    }
}
