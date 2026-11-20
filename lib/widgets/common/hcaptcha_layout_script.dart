/// 测量宿主文档中的题目框。只读外框尺寸，不访问验证框内部。
const hCaptchaLayoutScript = r'''
function watchHCaptchaLayout(mount, report) {
  if (typeof MutationObserver !== 'function' || typeof requestAnimationFrame !== 'function' || !document.head) return () => {};
  let queued = 0;
  let active = true;
  let lastHeight = 0;
  const frames = new Set();
  const resize = typeof ResizeObserver === 'function' ? new ResizeObserver(schedule) : null;
  const changes = new MutationObserver(schedule);
  // 验证提供方也在移动 SDK 中淡出外层遮罩。这里只清除空白背景的颜色，
  // 外层仍接收点按，题目、操作按钮、标识和隐私链接均由原控件绘制。
  const style = document.createElement('style');
  style.textContent = '[data-fluxdo-captcha-scrim] {background-color:transparent !important}';
  document.head.appendChild(style);
  const scrims = new Set();
  function schedule() {
    if (active && !queued) queued = requestAnimationFrame(measure);
  }
  function measure() {
    queued = 0;
    let height = 0;
    for (const frame of document.querySelectorAll('iframe')) {
      if (mount.contains(frame) || frame.closest('[inert]')) continue;
      if (!frames.has(frame)) {
        frames.add(frame);
        resize?.observe(frame);
      }
      const rect = frame.getBoundingClientRect();
      if (rect.width < 120 || rect.height < 120) continue;
      // 整页外框会随 WebView 自身改变，其高度不能反过来用于调整宿主。
      let fixedHeight = false;
      for (let node = frame; node && node !== document.body; node = node.parentElement) {
        const declared = node.style.height || (node === frame ? node.getAttribute('height') : '');
        if (/^\d+(\.\d+)?(px)?$/.test(declared || '') &&
            Math.abs(parseFloat(declared) - rect.height) <= 4) fixedHeight = true;
        const veil = node.children[1];
        if (veil?.matches('div:empty:not([role]):not([tabindex])') && !scrims.has(veil)) {
          const box = veil.getBoundingClientRect();
          if (box.width >= innerWidth - 2 && box.height >= innerHeight - 2) {
            veil.setAttribute('data-fluxdo-captcha-scrim', '');
            scrims.add(veil);
          }
        }
      }
      if (fixedHeight && Math.abs(rect.height - innerHeight) > 2) {
        height = Math.max(height, Math.ceil(rect.height));
      }
    }
    for (const frame of frames) {
      if (!frame.isConnected) { resize?.unobserve(frame); frames.delete(frame); }
    }
    if (height && height !== lastHeight) {
      lastHeight = height;
      report(height);
    }
  }
  changes.observe(document.body, {subtree:true, childList:true, attributes:true, attributeFilter:['height','width','style','class']});
  window.addEventListener('resize', schedule);
  schedule();
  return () => {
    active = false;
    changes.disconnect();
    resize?.disconnect();
    window.removeEventListener('resize', schedule);
    cancelAnimationFrame(queued);
    for (const veil of scrims) veil.removeAttribute('data-fluxdo-captcha-scrim');
    style.remove();
  };
}
''';
