package com.github.lingyan000.fluxdo

import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.LocusId
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 会话通知快捷方式通道,与 Dart 侧 LocalNotificationService 协议对应。
 *
 * Android 11+ 只有关联了「长期有效快捷方式」的 MessagingStyle 通知才按会话
 * 通知排版:左侧图标位显示快捷方式图标(发送者头像)并叠应用角标。否则左侧
 * 固定是应用图标,头像只能放进右侧 largeIcon。
 *
 * - push: 发布/更新会话快捷方式,返回是否成功。低于 Android 11 恒为 false,
 *   Dart 侧回退普通通知样式。
 * - remove: 通知发出后立即撤掉动态快捷方式,避免话题堆进桌面图标的长按菜单。
 *   系统在 notify 时已同步缓存该快捷方式,通知存续期间会话样式不受影响;
 *   相关通知全部移除后缓存由系统回收。
 *
 * 只用框架 API(均为 API 30 及以下引入),不额外引入 androidx.core。
 */
object ConversationShortcutChannel {
    private const val CHANNEL = "com.fluxdo/conversation_shortcut"
    private const val TAG = "ConversationShortcut"

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "push" -> result.success(push(appContext, call.arguments as? Map<*, *>))
                "remove" -> {
                    remove(appContext, call.argument<String>("id"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun push(context: Context, args: Map<*, *>?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || args == null) return false
        val id = args["id"] as? String ?: return false
        val label = (args["label"] as? String)?.takeIf { it.isNotBlank() } ?: return false
        val senderName = (args["senderName"] as? String)?.takeIf { it.isNotBlank() } ?: return false
        val iconBytes = args["icon"] as? ByteArray
        return try {
            val icon = iconBytes
                ?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                ?.let { Icon.createWithBitmap(it) }
            val person = Person.Builder()
                .setName(senderName)
                .setKey(args["senderKey"] as? String)
                .setIcon(icon)
                .build()
            val builder = ShortcutInfo.Builder(context, id)
                .setShortLabel(label)
                .setLongLabel(label)
                // 快捷方式必须带 intent;从会话设置等系统入口点开时只需拉起应用
                .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
                .setLongLived(true)
                .setPerson(person)
                .setLocusId(LocusId(id))
            if (icon != null) builder.setIcon(icon)
            val manager = context.getSystemService(ShortcutManager::class.java) ?: return false
            manager.pushDynamicShortcut(builder.build())
            true
        } catch (e: Exception) {
            Log.w(TAG, "push failed: ${e.message}")
            false
        }
    }

    private fun remove(context: Context, id: String?) {
        if (id == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            context.getSystemService(ShortcutManager::class.java)?.removeDynamicShortcuts(listOf(id))
        } catch (e: Exception) {
            Log.w(TAG, "remove failed: ${e.message}")
        }
    }
}
