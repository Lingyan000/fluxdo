package com.github.lingyan000.fluxdo

import android.graphics.Rect
import android.os.Build
import androidx.core.graphics.Insets
import androidx.core.view.DisplayCutoutCompat
import androidx.core.view.WindowInsetsCompat

/** 把窗口安全区换算为网页坐标，处理工具栏动画中的部分重叠。 */
internal fun browserViewportInsets(value: Insets, viewport: Rect, window: Rect): Insets {
    if (viewport.isEmpty || !Rect.intersects(viewport, window)) return Insets.NONE
    fun overlap(inset: Int, gap: Int, extent: Int) =
        (inset - gap).coerceIn(0, minOf(inset, extent))
    return Insets.of(
        overlap(value.left, viewport.left - window.left, viewport.width()),
        overlap(value.top, viewport.top - window.top, viewport.height()),
        overlap(value.right, window.right - viewport.right, viewport.width()),
        overlap(value.bottom, window.bottom - viewport.bottom, viewport.height()),
    )
}

/** 只调整安全区；IME、系统手势及后续 Insets 更新继续传给 WebView。 */
@Suppress("DEPRECATION")
internal fun browserWindowInsets(insets: WindowInsetsCompat, viewport: Rect, window: Rect, fullscreen: Boolean = false): WindowInsetsCompat {
    // 全屏内容由插件直接挂到窗口下；沿用窗口 Insets，不套用后台普通网页的边界。
    if (fullscreen) return insets
    fun remaining(value: Insets) = browserViewportInsets(value, viewport, window)
    val cutout = insets.displayCutout
    val safeCutout = remaining(insets.getInsets(WindowInsetsCompat.Type.displayCutout()))
    val base = if (safeCutout == Insets.NONE) insets.consumeDisplayCutout() else insets
    val builder = WindowInsetsCompat.Builder(base)
    // Android 29 的 typed Insets 尚不能替代 DisplayCutout 内的安全边距。
    // Android 28 的部分刘海重叠无法重建，交给 Dart 实测后的留边回退。
    if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q && cutout != null && safeCutout != Insets.NONE) {
        builder.setDisplayCutout(DisplayCutoutCompat(
            Rect(safeCutout.left, safeCutout.top, safeCutout.right, safeCutout.bottom),
            cutout.boundingRects,
        ))
    }
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
        // 旧系统用同一组 systemWindowInsets 表示导航栏和 IME。键盘显示时保留
        // 原始底部高度及 stableInsets，让引擎继续识别 IME，不能将其当导航栏清零。
        // 不依赖 compat 的 IME 推断，它在缺少 rootWindowInsets 时会将导航栏也算作 IME。
        val system = insets.systemWindowInsets
        val safe = remaining(system)
        val bottom = if (system.bottom > insets.stableInsetBottom) system.bottom else safe.bottom
        return builder
            .setStableInsets(insets.stableInsets)
            .setSystemWindowInsets(Insets.of(safe.left, safe.top, safe.right, bottom))
            .build()
    }
    for (type in intArrayOf(
        WindowInsetsCompat.Type.statusBars(),
        WindowInsetsCompat.Type.navigationBars(),
        WindowInsetsCompat.Type.captionBar(),
        WindowInsetsCompat.Type.displayCutout(),
    )) {
        builder.setInsets(type, remaining(insets.getInsets(type)))
        builder.setInsetsIgnoringVisibility(type, remaining(insets.getInsetsIgnoringVisibility(type)))
    }
    return builder.build()
}
