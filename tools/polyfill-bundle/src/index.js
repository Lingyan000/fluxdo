// 注意: ensureHead 的同步插入逻辑放在 build.mjs 的 esbuild banner 里,
// 不能放这里。ES Module 的 import 副作用会被提升到模块顶部按顺序执行,
// IIFE 等模块体代码反而排在所有 import 之后 —— 那时 es-module-shims
// 早就因 document.head=null 崩了。banner 才是 bundle 最顶部的"真"入口。

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

// Eruda 设备内 DevTools: 没 Mac 做 Safari 远程调试时, 用户在 iPhone 上直接
// 点页面右下角 ⚙ 按钮打开完整 Console / Network / Elements / Sources 面板。
// 关键场景: Discourse 主 bundle 是跨域 SCRIPT 标签, 真正的 error stack 被
// WebKit cross-origin sanitization 吃掉, 日志里只能看到 "(sanitized cross-origin
// script error)"。Eruda 在页面同源 realm 内拿 console 输出 — 包括 Discourse
// 自家 try/catch + console.error 报的完整 stack, 以及每个 fetch 的具体状态。
import './eruda-init.js';
