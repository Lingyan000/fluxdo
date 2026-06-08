// 在 main frame 装 Eruda。等 body 出现后再 init (eruda 需要往 body
// 挂载 UI)。失败完全静默, 不影响业务。
import eruda from 'eruda';

function initEruda() {
  try {
    if (window.__fluxdoErudaInited) return;
    window.__fluxdoErudaInited = true;
    eruda.init({
      // Eruda 默认就是右下角小按钮, 不挡内容
      tool: ['console', 'network', 'elements', 'resources', 'sources', 'info'],
      defaults: {
        displaySize: 50,
        transparency: 0.95,
        theme: 'Dark',
      },
    });
  } catch (e) {
    // 静默失败
  }
}

// document.body 在 AT_DOCUMENT_START 时是 null。
// 优先等 DOMContentLoaded, 兜底用 MutationObserver 监 body 出现。
if (document.body) {
  initEruda();
} else if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initEruda, { once: true });
} else {
  // 已 interactive / complete 但 body 仍可能未就绪 (罕见), 短轮询
  var tries = 0;
  var iv = setInterval(function () {
    if (document.body) {
      clearInterval(iv);
      initEruda();
    } else if (++tries > 100) {
      clearInterval(iv);
    }
  }, 50);
}
