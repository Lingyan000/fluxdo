import 'dart:convert';

/// A small DOM adapter for the official host, kept separate from application
/// content. It only uses observed host markup; no Ember private state, RPC
/// dispatch or application-frame code is accessed.
abstract final class MiniAppHostAdapter {
  /// 官方加载器按文档内容同时更新两层 iframe 的 height 属性。
  /// 原生外壳使用固定视口，必须连同隔离宿主里的应用 iframe 一起适配，
  /// 否则内层按完整文档撑高、外层裁切，应用自己没有可滚动的溢出区域。
  /// 只在官方 frame-host 文档安装样式，不进入应用 runtime 或改变沙箱权限。
  static String frameViewportScript(Uri site) {
    final prefix = site.path.replaceFirst(RegExp(r'/$'), '');
    return '''(() => {
      if (window === window.top ||
          location.origin !== ${jsonEncode(site.origin)} ||
          location.pathname !== ${jsonEncode('$prefix/mini-app-api/frame-host')}) return;
      const fitted = new WeakSet();
      const fit = (element, rules) => {
        if (!element || fitted.has(element)) return;
        // 直接设置布局属性，兼容禁止内联样式表的 frame-host CSP。
        for (const [name, value] of Object.entries(rules)) {
          element.style.setProperty(name, value, 'important');
        }
        fitted.add(element);
      };
      const install = () => {
        const bounds = {width:'100%', height:'100%', margin:'0', padding:'0', overflow:'hidden'};
        fit(document.documentElement, bounds);
        fit(document.body, bounds);
        const frame = document.querySelector('body > iframe');
        fit(frame, {display:'block', width:'100%', height:'100%', 'min-height':'0', 'max-height':'none', border:'0'});
        return !!frame;
      };
      if (!install()) {
        const observer = new MutationObserver(() => {
          if (install()) observer.disconnect();
        });
        observer.observe(document, {childList:true, subtree:true});
      }
    })()''';
  }

  /// 官方 links.open 在权限确认后调用宿主 window.open。原生按钮的脚本点击
  /// 不具备浏览器 user activation，不能依赖 WebView 的弹窗/导航回调。
  /// 这里只接收可信主宿主已经执行的打开操作，通过宿主状态通知交回原生；
  /// 不监听应用 iframe 消息、不代替官方权限检查，也不创建第二个 WebView。
  static String navigationScript(Uri entry) =>
      '''(() => {
    if (window !== window.top ||
        location.origin !== ${jsonEncode(entry.origin)} ||
        location.pathname !== ${jsonEncode(entry.path)} ||
        globalThis.fluxdoMiniAppLinks) return;
    let pending = null, claimed = false, sequence = 0;
    const documentId = Date.now().toString(36) + Math.random().toString(36);
    Object.defineProperty(globalThis, 'fluxdoMiniAppLinks', {value: Object.freeze({
      peek: () => claimed ? null : pending,
      take: id => {
        if (!pending || claimed || pending.id !== id) return false;
        claimed = true;
        return true;
      },
      finish: id => {
        if (pending?.id === id) { pending = null; claimed = false; }
      },
      clear: () => { pending = null; claimed = false; }
    })});
    window.open = function(url) {
      if (typeof url !== 'string' || !url.trim() || url.length > 8192) return null;
      let target;
      try { target = new URL(url, location.href); } catch { return null; }
      if (!['https:', 'http:', 'mailto:', 'tel:'].includes(target.protocol) ||
          (['https:', 'http:'].includes(target.protocol) &&
           !target.href.startsWith(target.origin + '/'))) return null;
      // 一个确认周期只接受一个请求，重复回调不排队轰炸用户。
      if (!pending) pending = Object.freeze({id: documentId + ':' + (++sequence), url: target.href});
      globalThis.fluxdoMiniAppEvents?.notify();
      // 官方使用 noopener,noreferrer，本就不依赖返回窗口句柄。
      return null;
    };
  })()''';

  static String takeExternalLink(String id) =>
      'globalThis.fluxdoMiniAppLinks?.take(${jsonEncode(id)}) === true';

  static String finishExternalLink(String id) =>
      'globalThis.fluxdoMiniAppLinks?.finish(${jsonEncode(id)});';

  static const clearExternalLinks = 'globalThis.fluxdoMiniAppLinks?.clear();';

  static const css = '''
    .mini-app-page__header { display: none !important; }
    /* 仅接管已经呈现在原生层的权限提示，未知弹窗保留网页处理。 */
    dialog.mini-app-permission-dialog[data-fluxdo-native-prompt] {
      opacity: 0 !important; pointer-events: none !important;
    }
    dialog.mini-app-permission-dialog[data-fluxdo-native-prompt]::backdrop {
      background: transparent !important;
    }
    /* Mobile DMenu uses a portal outside the hidden page header. Hide only
       that portal while accessing its audio control, before it is inserted. */
    html[data-fluxdo-audio-access] #d-menu-portals {
      opacity: 0 !important; pointer-events: none !important;
      transition: none !important; animation: none !important;
    }
    html, body { margin: 0 !important; padding: 0 !important; overflow: hidden !important; }
    /* 只调整宿主。页面可用高度由原生视图决定，不能让多层各占一个视口，
       也不能漏掉带 height="640" 属性的真正 frame-host iframe。 */
    .mini-app-page {
      position: fixed !important; inset: 0 !important;
      display: flex !important; flex-direction: column !important;
      width: auto !important; height: auto !important;
      min-width: 0 !important; min-height: 0 !important;
      max-width: none !important; max-height: none !important;
      margin: 0 !important; padding: 0 !important; overflow: hidden !important;
      box-sizing: border-box !important;
    }
    .mini-app-loader, .mini-app-loader__viewport {
      flex: 1 1 0 !important;
      width: 100% !important; height: auto !important;
      min-width: 0 !important; min-height: 0 !important;
      max-width: none !important; max-height: none !important;
      margin: 0 !important; padding: 0 !important;
      box-sizing: border-box !important;
    }
    .mini-app-loader { display: flex !important; flex-direction: column !important; }
    .mini-app-loader__viewport {
      position: relative !important; overflow: hidden !important;
      border: 0 !important; border-radius: 0 !important; box-shadow: none !important;
    }
    .mini-app-loader__frame {
      position: absolute !important; inset: 0 !important;
      width: 100% !important; height: 100% !important;
      min-width: 0 !important; min-height: 0 !important;
      max-width: none !important; max-height: none !important;
      margin: 0 !important; padding: 0 !important; border: 0 !important;
    }
    .mini-app-loader__frame > iframe.mini-app-frame-host {
      display: block !important; width: 100% !important; height: 100% !important;
      min-width: 0 !important; min-height: 0 !important;
      max-width: none !important; max-height: none !important;
      border: 0 !important; margin: 0 !important; aspect-ratio: auto !important;
    }
    .mini-app-loader__loading {
      min-height: 0 !important; max-height: 100% !important;
      box-sizing: border-box !important; overflow: auto !important;
    }
  ''';

  static const snapshot = r'''(() => {
    const header = document.querySelector('.mini-app-page__header');
    const audio = document.querySelector('.mini-app-page__audio-trigger');
    const loader = document.querySelector('.mini-app-loader');
    const loading = loader?.querySelector('.mini-app-loader__loading');
    const frame = loader?.querySelector('iframe');
    const events = globalThis.fluxdoMiniAppEvents;
    const waitingForRender = !!loading?.hidden && !!frame && !!events && events.renderedFrame !== frame;
    const progress = loading?.querySelector('progress');
    const stage = loading?.querySelector('[data-role="stage"]');
    const detail = loading?.querySelector('[data-role="detail"]');
    const retry = loading?.querySelector('[data-action="retry"]');
    const dialog = document.querySelector('dialog.mini-app-permission-dialog[open]');
    let permission = null;
    if (dialog) {
      const title = dialog.querySelector('h2');
      const paragraphs = [...dialog.querySelectorAll('p')];
      const buttons = [...dialog.querySelectorAll('button')];
      // 已观察的宿主契约：有唯一标题 ID、取消和允许两个按钮。
      // 不接受应用 frame 消息，也不根据权限文案猜测 SDK 调用。
      if (title?.id && paragraphs.length >= 1 && buttons.length === 2 &&
          buttons[1].classList.contains('--primary') &&
          buttons.every(b => !b.disabled)) {
        const values = [title.id, title.textContent, ...paragraphs.map(p => p.textContent),
          ...buttons.map(b => b.textContent)];
        if (values.every(v => typeof v === 'string' && v.length < 4096)) {
          permission = { signature: JSON.stringify(values), title: title.textContent,
            action: paragraphs[0].textContent,
            notice: paragraphs.slice(1).map(p => p.textContent).join('\n'),
            reject: buttons[0].textContent, allow: buttons[1].textContent };
        }
      }
    }
    let release = null;
    try {
      const text = document.getElementById?.('fluxdo-mini-app-release')?.textContent;
      if (text && text.length < 65536) release = JSON.parse(text);
    } catch {}
    let bootFailure = null;
    try {
      const text = document.getElementById?.('fluxdo-mini-app-boot-failure')?.textContent;
      if (text && text.length < 2048) bootFailure = JSON.parse(text);
    } catch {}
    const measures = globalThis.performance?.getEntriesByName?.('discourse-mini-app:load') || [];
    const measure = measures[measures.length - 1];
    return { compatible: !!header,
      externalLink: globalThis.fluxdoMiniAppLinks?.peek() || null,
      release,
      bootFailure,
      performance: measure && !waitingForRender ? {startTime:measure.startTime, ...measure.detail} : null,
      engineMounted: document.querySelector('.mini-app-page')?.hasAttribute('data-fluxdo-mounted') || false,
      soundAvailable: !!audio && !audio.disabled || !!header?.hasAttribute('data-fluxdo-muted'),
      muted: audio ? audio.getAttribute('aria-pressed') !== 'true' :
        header?.hasAttribute('data-fluxdo-muted') ? header.getAttribute('data-fluxdo-muted') === 'true' : null,
      fullscreen: !!document.fullscreenElement,
      ready: !!loading?.hidden && !waitingForRender && !!frame,
      loading: !!loading && (!loading.hidden || waitingForRender),
      stage: stage?.textContent?.trim() || '',
      detail: detail?.textContent?.trim() || '',
      progress: progress?.hasAttribute('value') && progress.max > 0 ? progress.value / progress.max : null,
      failed: !!retry && !retry.hidden,
      permission, webPermission: !!dialog };
  })()''';

  /// 核对整份提示和当前 DOM，超时、刷新或被替换的请求不能误授权。
  /// claim 只隐藏已识别提示；answer 仍调用官方按钮，不持久化授权。
  static String permissionOperation(
    String signature, {
    bool? allow,
    bool release = false,
  }) =>
      '''(() => {
    const state = $snapshot;
    if (!state.permission || state.permission.signature !== ${jsonEncode(signature)}) return false;
    const dialog = document.querySelector('dialog.mini-app-permission-dialog[open]');
    if (!dialog) return false;
    ${release
          ? "dialog.removeAttribute('data-fluxdo-native-prompt');"
          : allow == null
          ? "dialog.setAttribute('data-fluxdo-native-prompt', '');"
          : "dialog.removeAttribute('data-fluxdo-native-prompt'); dialog.querySelectorAll('button')[${allow ? 1 : 0}].click();"}
    return true;
  })()''';

  static const retry = r'''(() => {
    const button = document.querySelector('.mini-app-loader__loading [data-action="retry"]');
    if (!button || button.hidden || button.disabled) return false;
    button.click(); return true;
  })()''';

  static const releasePermission = r'''(() => {
    document.querySelectorAll('dialog.mini-app-permission-dialog[data-fluxdo-native-prompt]')
      .forEach(dialog => dialog.removeAttribute('data-fluxdo-native-prompt'));
  })()''';

  // On narrow layouts the official audio control lives in the more menu.
  // Activate that actual control instead of guessing the SDK message protocol.
  /// Function body for callAsyncJavaScript, with a boolean `toggle` argument.
  /// evaluateJavascript does not await returned Promises on all WebViews.
  static const soundOperation = r'''
    const header = document.querySelector('.mini-app-page__header');
    if (!header) return {available: false};
    const root = document.documentElement;
    const previousFocus = document.activeElement;
    const wait = () => new Promise(resolve => setTimeout(resolve, 30));
    let audio = document.querySelector('.mini-app-page__audio-trigger');
    let menu, opened = false;
    try {
      if (!audio) {
        // 后台探测只读 DOM，不能为了查状态打开隐藏菜单、抢走网页焦点。
        // 特别是原生 select/日期选择器，会因焦点变化刚打开就关闭。
        if (!toggle) return {available: false};
        menu = document.querySelector('.mini-app-page__more-trigger');
        if (!menu) return {available: false};
        root.setAttribute('data-fluxdo-audio-access', '');
        if (menu.getAttribute('aria-expanded') !== 'true') {
          menu.click();
          opened = true;
        }
        for (let i = 0; i < 30 && !audio; i++) {
          await wait();
          audio = document.querySelector('.mini-app-page__audio-trigger');
        }
      }
      if (!audio || audio.disabled) return {available: false};
      if (toggle) {
        const before = audio.getAttribute('aria-pressed');
        audio.click();
        // The official host may change audio asynchronously. Observe its DOM,
        // never infer success by flipping a local boolean.
        for (let i = 0; i < 40; i++) {
          await wait();
          if (!audio.disabled && audio.getAttribute('aria-pressed') !== before) break;
        }
      }
      const muted = audio.getAttribute('aria-pressed') !== 'true';
      header.setAttribute('data-fluxdo-muted', String(muted));
      return {available: true, muted};
    } finally {
      if (opened && menu?.getAttribute('aria-expanded') === 'true') menu.click();
      // Keep the portal suppressed through its closing transition, including
      // a timeout path; no unrelated permission dialog is hidden.
      if (opened) {
        for (let i = 0; i < 20 && document.querySelector('.mini-app-page__more-menu'); i++) await wait();
      }
      if (!document.querySelector('.mini-app-page__more-menu')) root.removeAttribute('data-fluxdo-audio-access');
      if (opened && previousFocus?.isConnected) previousFocus.focus({preventScroll: true});
    }
  ''';
}
