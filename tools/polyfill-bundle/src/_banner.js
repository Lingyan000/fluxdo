// 这个文件不是 ES Module entry,build.mjs 读它的内容塞到 esbuild banner,
// 让它在 bundle 最顶部、所有 import 副作用之前执行。
//
// 两个 patch 必须最早:
//   1. ensureHead   — es-module-shims 启动前 document.head 必须存在
//   2. SCRIPT.src patch — 在 HTML parser 解析 <script src="cdn3..."> 之前
//      hook Element.prototype.setAttribute,自动给跨域 SCRIPT 加
//      crossorigin="anonymous",突破 WebKit cross-origin script error
//      sanitization,让 Discourse 主 bundle 抛错时 stack 直接可见。
//
// 两个都是同步、容错、首次执行,不会有副作用扩散。

(function () {
  // ===== 1) ensureHead =====
  try {
    if (
      typeof document !== 'undefined' &&
      document.documentElement &&
      !document.head
    ) {
      document.documentElement.insertBefore(
        document.createElement('head'),
        document.documentElement.firstChild,
      );
    }
  } catch (e) {}

  // ===== 2) SCRIPT cross-origin patch =====
  // HTML parser 解析 <script src="..."> 时走 setAttribute("src", ...)
  // (不走 .src setter 也不走 createElement)。我们 patch 全局
  // Element.prototype.setAttribute,在 SCRIPT 上设 src 且 src 跨域且
  // 没 crossorigin 属性时,先把 crossorigin="anonymous" 设上,再 set src。
  // Script 此时还没挂到 DOM,fetch 还没开始 → crossorigin 生效。
  // cdn3.ldstatic.com 已经返 ACAO https://linux.do,所以加 crossorigin 后
  // window.error 拿到的就是完整 stack(不再 sanitize)。
  try {
    if (typeof Element !== 'undefined' && Element.prototype) {
      var origSetAttribute = Element.prototype.setAttribute;
      var pageOrigin =
        typeof location !== 'undefined' && location.origin
          ? location.origin
          : '';
      Element.prototype.setAttribute = function (name, value) {
        try {
          if (
            pageOrigin &&
            this &&
            this.tagName === 'SCRIPT' &&
            typeof name === 'string' &&
            name.toLowerCase() === 'src' &&
            typeof value === 'string' &&
            !this.hasAttribute('crossorigin')
          ) {
            // 简单跨域检测:相对路径 / 同 origin 跳过,绝对路径才解析
            var isProto =
              value.indexOf('http:') === 0 ||
              value.indexOf('https:') === 0 ||
              value.indexOf('//') === 0;
            if (isProto) {
              var srcOrigin = new URL(value, location.href).origin;
              if (srcOrigin !== pageOrigin) {
                origSetAttribute.call(this, 'crossorigin', 'anonymous');
              }
            }
          }
        } catch (_) {}
        return origSetAttribute.apply(this, arguments);
      };
    }
  } catch (e) {}
})();
