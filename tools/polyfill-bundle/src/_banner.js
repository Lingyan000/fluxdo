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

  // ===== 2) SCRIPT cross-origin patch (域白名单) =====
  // HTML parser 解析 <script src="..."> 走 setAttribute("src",...),
  // 我们 hook 这里加 crossorigin="anonymous",突破 WebKit cross-origin
  // script error sanitization,让 Discourse 主 bundle 抛错时 stack 完整可见。
  //
  // 危险:如果某 CDN 没返 ACAO,加了 crossorigin 反而 CORS 拒绝加载该 script,
  // 让站点比之前更糟。所以严格白名单 — 只对**已确认返 ACAO**的域生效。
  // 当前白名单:*.ldstatic.com (linux.do 的 Discourse 静态资源 CDN,curl 验过)。
  // 其他第三方 (Stripe / Google / CF turnstile) 不动 — 它们的 error 本就
  // sanitize 拿不到,我们不亏;但万一不返 ACAO 也不会破坏加载。
  var CROSS_ORIGIN_WHITELIST = /^https?:\/\/[a-z0-9-]+\.ldstatic\.com\//i;
  try {
    if (typeof Element !== 'undefined' && Element.prototype) {
      var origSetAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        try {
          if (
            this &&
            this.tagName === 'SCRIPT' &&
            typeof name === 'string' &&
            name.toLowerCase() === 'src' &&
            typeof value === 'string' &&
            CROSS_ORIGIN_WHITELIST.test(value) &&
            !this.hasAttribute('crossorigin')
          ) {
            origSetAttribute.call(this, 'crossorigin', 'anonymous');
          }
        } catch (_) {}
        return origSetAttribute.apply(this, arguments);
      };
    }
  } catch (e) {}
})();
