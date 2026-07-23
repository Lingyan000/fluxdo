package com.github.lingyan000.fluxdo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.RemoteException
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine

/**
 * 金标联盟「公平运行内存机制」接入(ITGSA,vivo/小米/OPPO/荣耀等)。
 *
 * 契约(小米 HyperOS 开发者文档 pId=2304):应用 PSS 或 Java 堆触达系统
 * 阈值时,系统发 [ITGSA_ACTION] 广播(common/extra 双 Bundle),应用须在
 * 3 秒内通过随广播下发的 Binder callback 回执,并尽力释放内存;持续增长
 * 触达查杀线会再收一次(reason/action 字段区分),之后进程被杀。
 *
 * 实现要点:
 * - 先回执再释放:3 秒是硬限,释放动作 best-effort 异步做,不阻塞回执;
 * - 释放通路 = Flutter 标准 memoryPressure:把厂商广播翻译成
 *   SystemChannel.sendMemoryPressureWarning(),Dart 侧统一走
 *   didHaveMemoryPressure(imageCache 框架自清 + 解析/flatten 缓存),
 *   与 iOS 内存警告同一入口,不另设私有通道;
 * - RECEIVER_EXPORTED 照文档要求(厂商系统侧发送方非本应用);伪造广播
 *   的危害上限只是"缓存被清一次 + 向伪造 binder 回执一个 result=0",
 *   无敏感数据外泄,可接受;
 * - 非金标联盟 ROM(原生 Android/三星/海外机型)永远收不到该广播,
 *   注册本身零成本,无需机型判断。
 */
object FairMemoryReceiver : IBinder.DeathRecipient {
    private const val TAG = "FairMemory"
    private const val ITGSA_ACTION = "itgsa.intent.action.TRIM"
    private val TRANSACTION_EXCEPTION_REPLY = IBinder.FIRST_CALL_TRANSACTION

    /** notifyType=1000:物理内存(PSS)异常,extra 携带 pss/pssLimit(kB) */
    private const val NOTIFY_TYPE_PSS = 1000

    /** notifyType=2000:Java 堆异常,extra 携带 heapAlloc/heapCapacity。
     *  Flutter 应用 Java 堆极小(内存大头在 Dart 堆/纹理),基本不会触发。 */
    private const val NOTIFY_TYPE_JAVA_HEAP = 2000

    private var initialized = false
    private var remote: IBinder? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 主 engine 引用:收到预警时向 Dart 转发标准 memoryPressure。
     *  engine 未起/已销毁时静默跳过(回执不受影响)。 */
    @Volatile
    private var engine: FlutterEngine? = null

    fun attachEngine(e: FlutterEngine) {
        engine = e
    }

    fun detachEngine(e: FlutterEngine) {
        if (engine === e) engine = null
    }

    /** 进程级注册(Application.onCreate),广播在专用 HandlerThread 处理。 */
    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        val thread = HandlerThread(TAG).also { it.start() }
        val handler = Handler(thread.looper)
        val filter = IntentFilter(ITGSA_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                receiver, filter, null, handler, Context.RECEIVER_EXPORTED
            )
        } else {
            context.registerReceiver(receiver, filter, null, handler)
        }
        initialized = true
        Log.i(TAG, "公平内存接收器已注册")
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ITGSA_ACTION) return
            try {
                val data = intent.extras ?: return
                val common = data.getBundle("common") ?: return
                val notifyType = common.getInt("notifyType")
                val notifyId = common.getInt("notifyId")
                val reason = common.getString("reason")
                val action = common.getString("action")
                val callback = common.getBinder("callback")

                // extra 仅作观测(阈值由系统动态定,应用侧不做数值决策);
                // 个别厂商实现可能缺失,可空容忍。
                val extra = data.getBundle("extra")
                val detail = when (notifyType) {
                    NOTIFY_TYPE_PSS ->
                        "pss=${extra?.getInt("pss")}kB limit=${extra?.getInt("pssLimit")}kB"
                    NOTIFY_TYPE_JAVA_HEAP ->
                        "heapAlloc=${extra?.getInt("heapAlloc")} heapCapacity=${extra?.getInt("heapCapacity")}"
                    else -> "extra=$extra"
                }
                Log.i(
                    TAG,
                    "收到公平内存广播: notifyType=$notifyType notifyId=$notifyId " +
                        "reason=$reason action=$action $detail"
                )

                if (callback == null) {
                    Log.w(TAG, "广播缺少 callback binder,跳过回执")
                } else if (checkRemote(callback)) {
                    // 回执在前(3 秒硬限内完成),释放在后
                    reply(notifyType, notifyId, 0, null)
                }
                dispatchMemoryPressure()
            } catch (e: Throwable) {
                Log.e(TAG, "处理公平内存广播失败: ${e.message}", e)
            }
        }
    }

    /** 向 Dart 转发 Flutter 标准内存压力信号(平台主线程调用)。 */
    private fun dispatchMemoryPressure() {
        mainHandler.post {
            try {
                engine?.systemChannel?.sendMemoryPressureWarning()
            } catch (e: Throwable) {
                Log.w(TAG, "转发 memoryPressure 失败: ${e.message}")
            }
        }
    }

    override fun binderDied() {
        synchronized(this) {
            remote?.let {
                try {
                    it.unlinkToDeath(this, 0)
                } catch (_: Throwable) {
                }
            }
            remote = null
        }
    }

    private fun checkRemote(callback: IBinder): Boolean {
        synchronized(this) {
            if (remote == null) {
                try {
                    remote = callback
                    callback.linkToDeath(this, 0)
                } catch (e: RemoteException) {
                    remote = null
                    return false
                }
            }
        }
        return true
    }

    /** Binder 回执(文档协议:notifyType/notifyId/result/extra 顺序,oneway)。 */
    private fun reply(notifyType: Int, notifyId: Int, result: Int, extra: Bundle?) {
        synchronized(this) {
            val target = remote ?: return
            val data = Parcel.obtain()
            val replyParcel = Parcel.obtain()
            try {
                data.writeInt(notifyType)
                data.writeInt(notifyId)
                data.writeInt(result)
                data.writeBundle(extra ?: Bundle())
                target.transact(
                    TRANSACTION_EXCEPTION_REPLY, data, replyParcel, IBinder.FLAG_ONEWAY
                )
                replyParcel.readException()
            } catch (e: Throwable) {
                Log.e(TAG, "回执失败: ${e.message}", e)
            } finally {
                replyParcel.recycle()
                data.recycle()
            }
        }
    }
}
