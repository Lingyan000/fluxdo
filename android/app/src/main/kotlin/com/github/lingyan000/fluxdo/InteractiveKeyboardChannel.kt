package com.github.lingyan000.fluxdo

import android.annotation.TargetApi
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Activity
import android.graphics.Insets
import android.os.Build
import android.os.CancellationSignal
import android.view.WindowInsets
import android.view.WindowInsetsAnimationControlListener
import android.view.WindowInsetsAnimationController
import android.view.animation.PathInterpolator
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Android 11+ 的真实 IME 控制；Flutter 只同步工具栏占位，不模拟键盘图片。 */
class InteractiveKeyboardChannel(activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.fluxdo/interactive_keyboard")
    private val ime = if (Build.VERSION.SDK_INT >= 30) ControlledIme(activity, channel) else null

    init {
        if (ime == null) channel.setMethodCallHandler { call, result ->
            if (call.method == "begin") result.success(mapOf("supported" to false))
            else result.success(null)
        }
    }
    fun cancel() { ime?.cancel() }
    fun dispose() { ime?.dispose(); channel.setMethodCallHandler(null) }
}

// 旧 Android 不加载包含 API 30 类型的实现类，避免类验证阶段出错。
@TargetApi(30)
private class ControlledIme(private val activity: Activity, private val channel: MethodChannel) {
    private var session: Int? = null
    private var control: WindowInsetsAnimationController? = null
    private var signal: CancellationSignal? = null
    private var animator: ValueAnimator? = null
    private var pendingBegin: MethodChannel.Result? = null
    private var pendingEnd: MethodChannel.Result? = null
    private val density get() = activity.resources.displayMetrics.density

    init {
        channel.setMethodCallHandler { call, result ->
            val id = call.argument<Number>("session")?.toInt()
            if (id == null) {
                result.error("INVALID_SESSION", "Missing keyboard session", null)
            } else when (call.method) {
                "begin" -> begin(id, result)
                "update" -> {
                    if (session == id) {
                        control?.takeIf { it.isReady }?.let { controller ->
                            val distance = (call.argument<Number>("distance")?.toDouble() ?: 0.0)
                            val bottom = (controller.shownStateInsets.bottom - distance * density).toInt()
                            setBottom(controller, bottom)
                        }
                    }
                    result.success(null)
                }
                "end" -> end(id, call.argument<Boolean>("dismiss") == true, result)
                "cancel" -> { if (session == id) cancel(dismiss = call.argument<Boolean>("dismiss") == true); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun begin(id: Int, result: MethodChannel.Result) {
        cancel()
        val insets = activity.window.decorView.rootWindowInsets
        val insetsController = activity.window.insetsController
        if (insets == null || !insets.isVisible(WindowInsets.Type.ime()) || insetsController == null) {
            result.success(mapOf("supported" to false))
            return
        }
        session = id
        pendingBegin = result
        val cancellation = CancellationSignal()
        signal = cancellation
        try {
            insetsController.controlWindowInsetsAnimation(
                WindowInsets.Type.ime(), -1, null, cancellation,
                object : WindowInsetsAnimationControlListener {
                    override fun onReady(controller: WindowInsetsAnimationController, types: Int) {
                        if (session != id) { controller.finish(true); return }
                        control = controller
                        pendingBegin?.success(mapOf("supported" to true,
                            "height" to controller.shownStateInsets.bottom / density))
                        pendingBegin = null
                    }
                    override fun onFinished(controller: WindowInsetsAnimationController) {
                        if (session == id) { control = null; signal = null }
                    }
                    override fun onCancelled(controller: WindowInsetsAnimationController?) {
                        if (session != id) return
                        cancel(notify = true)
                    }
                },
            )
        } catch (_: RuntimeException) {
            cancel(notify = false)
            return
        }
        // 系统可能拒绝控制权；手势不能一直等待一个不来的 onReady。
        activity.window.decorView.postDelayed({
            if (session == id && pendingBegin != null) cancel(notify = false)
        }, 1000)
    }

    private fun setBottom(controller: WindowInsetsAnimationController, requested: Int) {
        if (!controller.isReady) return
        val shown = controller.shownStateInsets
        val hidden = controller.hiddenStateInsets
        val bottom = requested.coerceIn(hidden.bottom, shown.bottom)
        val span = shown.bottom - hidden.bottom
        val shownFraction = if (span > 0) (bottom - hidden.bottom).toFloat() / span else 0f
        controller.setInsetsAndAlpha(Insets.of(shown.left, shown.top, shown.right, bottom), 1f, 1f - shownFraction)
    }

    private fun end(id: Int, dismiss: Boolean, result: MethodChannel.Result) {
        if (session != id) { result.success(null); return }
        val controller = control
        if (controller == null || !controller.isReady) { result.success(null); return }
        pendingEnd = result
        val target = if (dismiss) controller.hiddenStateInsets.bottom else controller.shownStateInsets.bottom
        animator = ValueAnimator.ofInt(controller.currentInsets.bottom, target).apply {
            duration = 300
            interpolator = PathInterpolator(.42f, 0f, .58f, 1f)
            addUpdateListener { if (session == id) setBottom(controller, it.animatedValue as Int) }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (session != id) return
                    if (controller.isReady) controller.finish(!dismiss)
                    control = null
                    signal = null
                    animator = null
                    session = null
                    pendingEnd?.success(null)
                    pendingEnd = null
                }
            })
            start()
        }
    }

    fun cancel(notify: Boolean = true, dismiss: Boolean = false) {
        val id = session
        session = null // 先清会话，防止系统取消回调重入。
        animator?.cancel()
        animator = null
        control?.takeIf { it.isReady }?.finish(!dismiss)
        control = null
        signal?.cancel()
        signal = null
        if (dismiss) activity.window.insetsController?.hide(WindowInsets.Type.ime())
        pendingBegin?.success(mapOf("supported" to false))
        pendingBegin = null
        pendingEnd?.success(null)
        pendingEnd = null
        if (notify && id != null) channel.invokeMethod("cancelled", mapOf("session" to id))
    }

    fun dispose() {
        cancel()
        channel.setMethodCallHandler(null)
    }
}
