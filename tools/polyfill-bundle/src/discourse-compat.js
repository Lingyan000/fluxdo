// 绕过 Discourse 老 WKWebView 浏览器兼容性检测，让 iOS 15 / 老 Safari 能进入 Ember app。
//
// 根因（在 discourse 仓库里挖到的）：
//   frontend/discourse/scripts/browser-detect.js 用 CSS.supports 检测
//   subgrid (Safari 16+) / relative color (Safari 16.4+) 等 CSS 特性；
//   iOS 15 都缺 → 设 window.unsupportedBrowser = true →
//   frontend/discourse/public/assets/scripts/discourse-boot.js 第 2-4 行直接
//   `throw "Unsupported browser detected"`，整个 Ember app 不启动。
//
// 跟 ES API polyfill 完全无关 —— core-js 救不了 CSS 渲染引擎能力。
//
// 策略（双保险）：
// 1. patch CSS.supports，对 Discourse 当前检测的 3 个 query 返回 true；
// 2. Object.defineProperty 把 window.unsupportedBrowser 锁为 false (read-only)，
//    兜底将来 Discourse 加新检测项也不会被设上。
//
// 副作用：iOS 15 上 Discourse 真正用 subgrid / relative color 排版的地方，CSS
// 会回退到不带这些特性的样式，UI 可能不完美但功能可用。比 app 完全启动不了好。
//
// 必须在 Discourse 任何脚本之前跑（AT_DOCUMENT_START 注入，由 polyfill bundle 保证）。
(function () {
  'use strict';

  // ===== 1) patch CSS.supports =====
  // 严格白名单匹配 discourse/scripts/browser-detect.js 写的 query 字符串：
  var FORCE_SUPPORTED = [
    'aspect-ratio: 1',
    '(color: hsl(from white h s l))',
    '(grid-template-rows: subgrid)',
  ];
  try {
    if (typeof CSS !== 'undefined' && typeof CSS.supports === 'function') {
      var origSupports = CSS.supports.bind(CSS);
      CSS.supports = function () {
        try {
          if (arguments.length === 1 && typeof arguments[0] === 'string') {
            var q = arguments[0];
            for (var i = 0; i < FORCE_SUPPORTED.length; i++) {
              if (q === FORCE_SUPPORTED[i]) return true;
            }
          }
          return origSupports.apply(null, arguments);
        } catch (_) {
          return false;
        }
      };
    }
  } catch (_) {}

  // ===== 2) 锁 window.unsupportedBrowser = false =====
  // sloppy mode 下后续 `window.unsupportedBrowser = true` 会静默失败。
  // browser-detect.js 没有 'use strict'，所以不会抛错。
  try {
    Object.defineProperty(window, 'unsupportedBrowser', {
      value: false,
      writable: false,
      configurable: false,
    });
  } catch (_) {}

  // ===== 3) patch document.createElement 给 script 加 crossorigin =====
  // 突破 WebKit 的 cross-origin script error sanitization。
  // cdn*.ldstatic.com 实测已返回 Access-Control-Allow-Origin: https://linux.do，
  // 给 script 加 crossorigin="anonymous" 后，window.error 能拿到完整 stack 而非
  // "(sanitized cross-origin script error)"。
  // 只 patch JS 动态 createElement 创建的 script (Ember Loader 加载主 bundle 走这条),
  // server-side HTML 里的 <script> 标签 patch 不到。
  try {
    var origCreateElement = document.createElement;
    document.createElement = function (tagName) {
      var el = origCreateElement.apply(this, arguments);
      try {
        if (typeof tagName === 'string' && tagName.toLowerCase() === 'script') {
          el.crossOrigin = 'anonymous';
        }
      } catch (_) {}
      return el;
    };
  } catch (_) {}

  // ===== 4) AbortSignal.timeout / AbortSignal.any polyfill =====
  // Safari 17.4+ 才有，core-js 不覆盖 (它们是 WHATWG DOM API，不属 ECMAScript)。
  // 启动期 probes 报这俩 missing，Discourse 主 bundle 或其依赖大概率用到了。
  try {
    if (typeof AbortSignal !== 'undefined') {
      if (typeof AbortSignal.timeout !== 'function') {
        AbortSignal.timeout = function (ms) {
          var ctrl = new AbortController();
          setTimeout(function () {
            try {
              ctrl.abort(new DOMException('TimeoutError', 'TimeoutError'));
            } catch (_) {
              ctrl.abort();
            }
          }, ms);
          return ctrl.signal;
        };
      }
      if (typeof AbortSignal.any !== 'function') {
        AbortSignal.any = function (signals) {
          var ctrl = new AbortController();
          var arr = Array.prototype.slice.call(signals);
          // 已 aborted 的 signal 立即触发
          for (var i = 0; i < arr.length; i++) {
            var s = arr[i];
            if (s && s.aborted) {
              try { ctrl.abort(s.reason); } catch (_) { ctrl.abort(); }
              return ctrl.signal;
            }
          }
          var onAbort = function (e) {
            try { ctrl.abort(e.target && e.target.reason); } catch (_) { ctrl.abort(); }
            for (var j = 0; j < arr.length; j++) {
              try { arr[j].removeEventListener('abort', onAbort); } catch (_) {}
            }
          };
          for (var k = 0; k < arr.length; k++) {
            try { arr[k].addEventListener('abort', onAbort, { once: true }); } catch (_) {}
          }
          return ctrl.signal;
        };
      }
    }
  } catch (_) {}
})();
