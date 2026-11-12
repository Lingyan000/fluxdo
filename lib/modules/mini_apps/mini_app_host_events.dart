import 'dart:convert';

import 'mini_app_host_adapter.dart';

/// 可信宿主主动上报状态，原生层按页面绑定校验，慢速轮询负责恢复遗漏。
abstract final class MiniAppHostEvents {
  static const handler = 'fluxdoMiniAppState';

  static String install(Uri entry, String token) =>
      '''(() => {
    if (window !== window.top || location.origin !== ${jsonEncode(entry.origin)} ||
        location.pathname !== ${jsonEncode(entry.path)}) return false;
    let renderedFrame = globalThis.fluxdoMiniAppEvents?.renderedFrame || null;
    globalThis.fluxdoMiniAppEvents?.dispose();
    const token = ${jsonEncode(token)};
    const lifetime = new AbortController();
    let timer, sending = false, dirty = false, previous, sequence = 0;
    let pendingFrame, renderRequest;
    function readyFrame() {
      const loader = document.querySelector('.mini-app-loader');
      const loading = loader?.querySelector('.mini-app-loader__loading');
      return loading?.hidden ? loader.querySelector('iframe') : null;
    }
    function read() {
      const frame = readyFrame();
      if (!frame || (frame !== renderedFrame && frame !== pendingFrame)) {
        cancelAnimationFrame(renderRequest);
        renderedFrame = null;
        pendingFrame = frame;
        if (frame) {
          // 两套宿主都在 app-rendered 后隐藏加载层，再等待两帧提交绘制。
          renderRequest = requestAnimationFrame(() => {
            renderRequest = requestAnimationFrame(() => {
              pendingFrame = null;
              if (lifetime.signal.aborted) return;
              if (readyFrame() === frame) renderedFrame = frame;
              notify();
            });
          });
        }
      }
      return ${MiniAppHostAdapter.snapshot};
    }
    function notify() {
      if (lifetime.signal.aborted) return;
      dirty = true;
      if (!timer && !sending) timer = setTimeout(flush, 16);
    }
    async function flush() {
      timer = undefined;
      if (lifetime.signal.aborted || sending) return;
      dirty = false;
      const state = read();
      const bridge = globalThis.flutter_inappwebview;
      if (typeof bridge?.callHandler !== 'function') return;
      const serialized = JSON.stringify(state);
      if (serialized === previous || serialized.length > 65536) return;
      sending = true;
      try {
        const accepted = await bridge.callHandler('$handler', {
          token, sequence: ++sequence, state,
        });
        if (accepted === true) previous = serialized;
      } catch { /* 原生层继续通过兜底读取恢复状态。 */ }
      finally {
        sending = false;
        if (dirty) notify();
      }
    }
    const observer = new MutationObserver(notify);
    observer.observe(document.documentElement, {
      subtree: true, childList: true, characterData: true, attributes: true,
      attributeFilter: ['class', 'hidden', 'value', 'max', 'aria-pressed',
        'open', 'disabled', 'data-fluxdo-mounted', 'data-fluxdo-muted'],
    });
    let performanceObserver;
    if (typeof PerformanceObserver === 'function') {
      performanceObserver = new PerformanceObserver(notify);
      performanceObserver.observe({entryTypes: ['measure']});
    }
    function dispose() {
      lifetime.abort();
      clearTimeout(timer);
      cancelAnimationFrame(renderRequest);
      observer.disconnect();
      performanceObserver?.disconnect();
    }
    globalThis.fluxdoMiniAppEvents = Object.freeze({notify, dispose,
      get renderedFrame() { return renderedFrame; },
    });
    for (const name of ['fullscreenchange', 'visibilitychange']) {
      document.addEventListener(name, notify, {signal: lifetime.signal});
    }
    window.addEventListener('flutterInAppWebViewPlatformReady', notify, {signal: lifetime.signal});
    window.addEventListener('pagehide', dispose, {once: true, signal: lifetime.signal});
    const initial = read();
    notify();
    return initial;
  })()''';
}
