// AT_DOCUMENT_START 时 HTML parser 还没扫到 <head>，document.head 是 null。
// es-module-shims 启动时会 document.head.appendChild(modulepreload link) 直接
// TypeError 把自己崩掉，于是 importmap 没人接管 → Discourse bundle 还是
// resolve 失败 → splash 永驻。提前同步插入一个空 head，parser 后续遇到
// HTML 里的 <head> 会复用同一个，无副作用。
//
// (这条修复是从 iOS 15.7 实测日志反推: error stack 指向 user-script:15:6:118511
//  的 document.head.appendChild,说明 es-module-shims 内部因 head=null 自己挂了。)
if (typeof document !== 'undefined' && document.documentElement) {
  try {
    if (!document.head) {
      document.documentElement.insertBefore(
        document.createElement('head'),
        document.documentElement.firstChild,
      );
    }
  } catch (e) {}
}

// es-module-shims: 给 Safari < 16.4 polyfill import maps + 现代 module 加载。
// 必须放最前 —— linux.do 用 <script type="importmap"> 加 <script type="module">
// 加载 vendor / discourse 主 bundle，iOS 15.7 不识别 importmap，bare specifier
// (import "ember-source" 之类) 无法 resolve，整个 Ember app 起不来。
// es-module-shims 通过 fetch + 重写 import + Blob URL 接管。
// AT_DOCUMENT_START 注入保证在 HTML parser 扫到 <script> 之前 ready。
import 'es-module-shims';

// 绕过 Discourse 在 iOS 15 上的 CSS 特性检测，必须在 core-js 之前，
// 因为它是 Discourse boot 流程的"门"，过不去后面的 polyfill 都白搭。
import './discourse-compat.js';

// 入口：'core-js/actual' 这一行会被 @babel/preset-env (useBuiltIns: 'entry')
// 按 package.json 里的 browserslist (iOS >= 15.0) 展开成精确的
// `import 'core-js/modules/<feature>'` 列表，只引入老 WKWebView 缺失的 API。
//
// 用 `actual` 而非 `stable`：actual 包含 stage 4 已批准但浏览器尚未全部实现的
// 提案 (Iterator helpers / AbortSignal.any / Promise.try 等)，覆盖面更大，
// 避免 Discourse 升级后再次撞到没补的 API。
// 抬高基线 → 改 package.json 里的 browserslist，build 后产物自动缩小。
import 'core-js/actual';

// WebView 内 JS 运行时错误捕获 + 启动期 polyfill 自检，回传到 Dart 侧 LogWriter。
import './error-reporter.js';
