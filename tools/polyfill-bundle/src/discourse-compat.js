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
})();
