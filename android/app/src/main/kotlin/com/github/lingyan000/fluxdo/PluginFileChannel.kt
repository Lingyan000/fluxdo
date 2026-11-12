package com.github.lingyan000.fluxdo

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/** 使用文件管理器授予的临时读取权限，读取后交给 Dart 安装器校验。 */
object PluginFileChannel {
    private const val MAX_BYTES = 2 * 1024 * 1024

    fun register(context: Context, messenger: BinaryMessenger) {
        val resolver = context.applicationContext.contentResolver
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, "com.fluxdo/plugin_files").setMethodCallHandler { call, result ->
            if (call.method != "readFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val uri = (call.arguments as? String)?.let(Uri::parse)
            if (uri == null || uri.scheme != "content") {
                result.error("invalid_uri", "Invalid plugin file URI", null)
                return@setMethodCallHandler
            }
            Thread {
                try {
                    val name = resolver.query(
                        uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: uri.lastPathSegment
                    require(name?.endsWith(".fluxplugin", ignoreCase = true) == true) {
                        "Expected a .fluxplugin file"
                    }
                    val bytes = resolver.openInputStream(uri)?.use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            require(output.size() <= MAX_BYTES) { "Plugin file exceeds 2 MiB" }
                        }
                        output.toByteArray()
                    } ?: error("Cannot open plugin file")
                    main.post { result.success(bytes) }
                } catch (error: Exception) {
                    main.post { result.error("plugin_file_read", error.message, null) }
                }
            }.start()
        }
    }
}
