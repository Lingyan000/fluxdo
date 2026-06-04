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
