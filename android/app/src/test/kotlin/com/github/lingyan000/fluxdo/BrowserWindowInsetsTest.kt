package com.github.lingyan000.fluxdo

import android.graphics.Rect
import android.os.Build
import android.view.WindowInsets
import androidx.core.graphics.Insets
import androidx.core.view.DisplayCutoutCompat
import androidx.core.view.WindowInsetsCompat
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [24, 28, 29, 30, 35])
@Suppress("DEPRECATION")
class BrowserWindowInsetsTest {
    private val window = Rect(0, 0, 390, 844)
    private val chrome = Rect(0, 110, 390, 764)
    private val bars = WindowInsetsCompat.Type.systemBars()

    private fun insets(ime: Int = 0): WindowInsetsCompat {
        // 从未 consumed 的窗口通知构造；API 28 的空 Builder 默认复制 CONSUMED，
        // 后续 replaceSystemWindowInsets 不会清掉其中的消费标志。
        val raw = WindowInsets(Rect(0, 44, 0, maxOf(24, ime)))
        val builder = WindowInsetsCompat.Builder(WindowInsetsCompat.toWindowInsetsCompat(raw))
            .setSystemWindowInsets(Insets.of(0, 44, 0, maxOf(24, ime)))
            .setStableInsets(Insets.of(0, 44, 0, 24))
            .setDisplayCutout(DisplayCutoutCompat(Rect(0, 28, 0, 0), listOf(Rect(180, 0, 210, 28))))
        if (Build.VERSION.SDK_INT >= 30) {
            builder.setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, 44, 0, 0))
                .setVisible(WindowInsetsCompat.Type.statusBars(), true)
                .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, 24))
                .setVisible(WindowInsetsCompat.Type.navigationBars(), true)
                .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, ime))
                .setVisible(WindowInsetsCompat.Type.ime(), ime > 0)
                .setInsets(WindowInsetsCompat.Type.systemGestures(), Insets.of(8, 0, 8, 24))
        }
        return builder.build()
    }

    @Test fun toolbarLayoutsAndPartialOverlap() {
        val value = Insets.of(0, 44, 0, 24)
        assertEquals(Insets.NONE, browserViewportInsets(value, chrome, window))
        assertEquals(Insets.of(0, 44, 0, 0), browserViewportInsets(value, Rect(0, 0, 390, 764), window))
        assertEquals(Insets.of(0, 0, 0, 24), browserViewportInsets(value, Rect(0, 110, 390, 844), window))
        assertEquals(value, browserViewportInsets(value, window, window))
        assertEquals(Insets.of(0, 24, 0, 12), browserViewportInsets(value, Rect(0, 20, 390, 832), window))
    }

    @Test fun floatingWindowAndLandscapeCutouts() {
        assertEquals(Insets.of(27, 0, 27, 0), browserViewportInsets(
            Insets.of(47, 0, 47, 0), Rect(120, 50, 924, 440), Rect(100, 50, 944, 440),
        ))
        assertEquals(Insets.NONE, browserViewportInsets(Insets.of(47, 0, 0, 0), Rect(), window))
    }

    @Test fun handledInsetsAreZeroWithoutConsumingDispatch() {
        val result = browserWindowInsets(insets(), chrome, window)
        assertEquals(Insets.NONE, result.getInsets(bars or WindowInsetsCompat.Type.displayCutout()))
        assertFalse(result.isConsumed)
    }

    @Test fun typedInsetsPreserveKeyboardAndGestures() {
        assumeTrue(Build.VERSION.SDK_INT >= 30)
        val original = insets(300)
        val result = browserWindowInsets(original, chrome, window)
        assertEquals(Insets.NONE, result.getInsets(bars))
        for (type in intArrayOf(WindowInsetsCompat.Type.ime(), WindowInsetsCompat.Type.systemGestures())) {
            assertEquals(original.getInsets(type), result.getInsets(type))
            assertEquals(original.isVisible(type), result.isVisible(type))
        }
    }

    @Test fun legacyKeyboardHeightAndStableInsetsSurvive() {
        assumeTrue(Build.VERSION.SDK_INT < 30)
        val original = insets(300)
        val result = browserWindowInsets(original, chrome, window)
        assertEquals(300, result.systemWindowInsetBottom)
        assertEquals(original.stableInsets, result.stableInsets)
        assertEquals(0, result.systemWindowInsetTop)
    }

    @Test fun partialCutoutAndSystemBarOverlap() {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val result = browserWindowInsets(insets(), Rect(0, 20, 390, 832), window)
        assertEquals(Insets.of(0, 24, 0, 12), result.getInsets(bars))
        assertEquals(8, result.getInsets(WindowInsetsCompat.Type.displayCutout()).top)
    }

    @Test fun fullscreenUsesWindowInsetsThenRestoresViewport() {
        val original = insets()
        assertSame(original, browserWindowInsets(original, chrome, window, fullscreen = true))
        val restored = browserWindowInsets(original, chrome, window)
        assertEquals(Insets.NONE, restored.getInsets(bars or WindowInsetsCompat.Type.displayCutout()))
    }

    @Test fun invisibleSystemBarsDoNotRemoveTheCutout() {
        assumeTrue(Build.VERSION.SDK_INT >= 30)
        // 系统隐藏工具栏时同时下发零可见 Insets，最大 Insets 仍保留。
        val original = WindowInsetsCompat.Builder(insets())
            .setInsetsIgnoringVisibility(bars, Insets.of(0, 44, 0, 24))
            .setInsets(bars, Insets.NONE)
            .setVisible(bars, false)
            .build()
        val result = browserWindowInsets(original, window, window)
        assertEquals(Insets.NONE, result.getInsets(bars))
        assertEquals(28, result.getInsets(WindowInsetsCompat.Type.displayCutout()).top)
    }
}
