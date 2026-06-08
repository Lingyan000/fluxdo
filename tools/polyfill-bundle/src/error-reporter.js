// WebView 内 JS 错误回传 + polyfill 自检上报。
// 通过 `flutter_inappwebview.callHandler('onWebViewJsError', ...)` 落到 Dart LogWriter。
//
// 三类信号：
// 1) lifecycle 'compat_bundle_loaded' — 启动期自检：polyfill bundle 是否完整执行 +
//    一组已知 ES2022~2024 / stage 3 API 当前可用性。这条信号能突破跨域 sanitization
//    告诉我们「polyfill 跑没跑、Discourse 实际能用哪些 API」。
// 2) 'console.error' 拦截 — 突破跨域 sanitization 的关键。Discourse 自家
//    try/catch 输出的错误对象在 catch 块里是完整的（JS 层语义不受 sanitization
//    限制），通过包裹 console.error 拿到 stack。
// 3) 'window.error' / 'unhandledrejection' — 兜底捕获 uncaught 错误。
//    跨域脚本错误会被 WebKit sanitize 成 "Script error." + null，但同源错误完整。
(function () {
  if (window.__fluxdoErrHooked) return;
  window.__fluxdoErrHooked = true;

  var errCount = 0;
  var ERR_MAX = 30;
  var consoleErrCount = 0;
  var CONSOLE_ERR_MAX = 20;

  function safeStringify(v) {
    if (v == null) return null;
    if (typeof v === 'string') return v;
    if (typeof v === 'number' || typeof v === 'boolean') return String(v);
    try {
      var seen = [];
      return JSON.stringify(v, function (k, val) {
        if (typeof val === 'object' && val !== null) {
          if (seen.indexOf(val) !== -1) return '[circular]';
          seen.push(val);
        }
        if (typeof val === 'function') return '[function]';
        return val;
      });
    } catch (e) {
      try { return String(v); } catch (_) { return null; }
    }
  }

  function send(payload) {
    try {
      var h = window.flutter_inappwebview;
      if (h && h.callHandler) {
        h.callHandler('onWebViewJsError', payload);
      }
    } catch (_) {}
  }

  function reportError(payload) {
    if (errCount >= ERR_MAX) return;
    errCount++;
    send(payload);
  }

  // 跳过 about:blank / about:srcdoc 这类 stub frame:
  // es-module-shims 在 iOS 15 上为每个 module 创建 about:blank iframe 评估,
  // 实测 10 秒内能触发 1100+ 次 user script 注入。我们在每个 stub frame 都
  // 跑探针 + 发 lifecycle 信号 → callHandler 把 Flutter native bridge 打爆
  // → 主线程被霸占 → 后续 priming/GET 都来不及调度 → Discourse 永远启动不了。
  // 错误捕获仍然装上 (cheap),但探针 + lifecycle 信号只在真实页面跑。
  var isStubFrame =
    location.href === 'about:blank' || location.href === 'about:srcdoc';

  // ===== 1) 启动期自检：lifecycle 信号 + API 探针 =====
  // 用 typeof 防御未定义的全局 (Iterator / AbortSignal 等老 WebKit 可能没有)。
  function probe(getter) {
    try {
      return getter() ? true : false;
    } catch (_) {
      return false;
    }
  }
  if (isStubFrame) {
    // stub frame 不跑探针, 不发 lifecycle 信号, 直接进入错误捕获注册。
  } else {
  var probes = {
    // ES2022 (Safari 15.4)
    'Object.hasOwn': probe(function () { return typeof Object.hasOwn === 'function'; }),
    'Array.prototype.at': probe(function () { return typeof Array.prototype.at === 'function'; }),
    'String.prototype.at': probe(function () { return typeof String.prototype.at === 'function'; }),
    'Array.prototype.findLast': probe(function () { return typeof Array.prototype.findLast === 'function'; }),
    'Array.prototype.findLastIndex': probe(function () { return typeof Array.prototype.findLastIndex === 'function'; }),
    'structuredClone': probe(function () { return typeof structuredClone === 'function'; }),
    'Element.prototype.replaceChildren': probe(function () { return typeof Element !== 'undefined' && typeof Element.prototype.replaceChildren === 'function'; }),
    'crypto.randomUUID': probe(function () { return typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'; }),
    'Error.cause': probe(function () { return 'cause' in new Error('', { cause: 1 }); }),
    // ES2023 (Safari 16)
    'Array.prototype.toReversed': probe(function () { return typeof Array.prototype.toReversed === 'function'; }),
    'Array.prototype.toSorted': probe(function () { return typeof Array.prototype.toSorted === 'function'; }),
    'Array.prototype.toSpliced': probe(function () { return typeof Array.prototype.toSpliced === 'function'; }),
    'Array.prototype.with': probe(function () { return typeof Array.prototype['with'] === 'function'; }),
    // ES2024 (Safari 17/17.4)
    'Promise.withResolvers': probe(function () { return typeof Promise.withResolvers === 'function'; }),
    'Promise.any': probe(function () { return typeof Promise.any === 'function'; }),
    'Object.groupBy': probe(function () { return typeof Object.groupBy === 'function'; }),
    'Map.groupBy': probe(function () { return typeof Map.groupBy === 'function'; }),
    'Set.prototype.intersection': probe(function () { return typeof Set.prototype.intersection === 'function'; }),
    'Set.prototype.union': probe(function () { return typeof Set.prototype.union === 'function'; }),
    'Set.prototype.difference': probe(function () { return typeof Set.prototype.difference === 'function'; }),
    'Set.prototype.symmetricDifference': probe(function () { return typeof Set.prototype.symmetricDifference === 'function'; }),
    'Set.prototype.isSubsetOf': probe(function () { return typeof Set.prototype.isSubsetOf === 'function'; }),
    'Set.prototype.isSupersetOf': probe(function () { return typeof Set.prototype.isSupersetOf === 'function'; }),
    'Set.prototype.isDisjointFrom': probe(function () { return typeof Set.prototype.isDisjointFrom === 'function'; }),
    'AbortSignal.timeout': probe(function () { return typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function'; }),
    'AbortSignal.any': probe(function () { return typeof AbortSignal !== 'undefined' && typeof AbortSignal.any === 'function'; }),
    // Stage 3 (Safari 18.4+)
    'Promise.try': probe(function () { return typeof Promise['try'] === 'function'; }),
    'Iterator.prototype.map': probe(function () { return typeof Iterator !== 'undefined' && typeof Iterator.prototype.map === 'function'; }),
    'Iterator.prototype.filter': probe(function () { return typeof Iterator !== 'undefined' && typeof Iterator.prototype.filter === 'function'; }),
    'Iterator.prototype.toArray': probe(function () { return typeof Iterator !== 'undefined' && typeof Iterator.prototype.toArray === 'function'; }),
    'RegExp.escape': probe(function () { return typeof RegExp.escape === 'function'; }),
    // RegExp v flag (语法层，不可 polyfill；用 new RegExp + 'v' 检测)
    'RegExp /v flag': probe(function () { new RegExp('a', 'v'); return true; }),
  };
  // 把缺失的 API 单独列一份，方便日志一眼看
  var missing = [];
  for (var k in probes) {
    if (Object.prototype.hasOwnProperty.call(probes, k) && !probes[k]) missing.push(k);
  }
  send({
    source: 'lifecycle',
    message: 'compat_bundle_loaded',
    probes: probes,
    missing: missing,
    url: location.href,
    ua: navigator.userAgent,
  });

  // ===== Discourse boot 阶段追踪 =====
  // splash 永驻 + 无 error → Discourse 启动卡在某 await/事件等待。
  // 监听 Discourse boot 链路的关键节点,看具体卡哪一步。
  // 链路 (按时间顺序):
  //   1. DOMContentLoaded   - DOM 解析完
  //   2. window load        - 资源全部加载完(含 vendor/discourse bundle)
  //   3. discourse-init     - discourse-boot.js dispatch,触发 Ember.create
  //   4. discourse-ready    - Ember Application.ready() (移除 #d-splash 的时机)
  // 任何一步在 30 秒后还没触发 → 上报 'stalled_at_<step>',告诉我们卡在哪。
  function bootMark(stage, extra) {
    send({
      source: 'lifecycle',
      message: 'discourse_boot_' + stage,
      stage: stage,
      url: location.href,
      ua: navigator.userAgent,
      extra: extra || null,
    });
  }
  var bootStages = { dom: false, load: false, init: false, ready: false };
  function track(stage, fire) {
    if (bootStages[stage]) return;
    bootStages[stage] = true;
    bootMark(stage, fire);
  }
  try {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', function () { track('dom'); }, { once: true });
    } else {
      track('dom', 'already-' + document.readyState);
    }
    if (document.readyState !== 'complete') {
      window.addEventListener('load', function () { track('load'); }, { once: true });
    } else {
      track('load', 'already-complete');
    }
    document.addEventListener('discourse-init', function () { track('init'); }, { once: true });
    // ready 信号:监听 #d-splash 节点被移除 (app.js:157 触发)
    var splashWatch = setInterval(function () {
      if (!document.querySelector('#d-splash')) {
        clearInterval(splashWatch);
        track('ready');
      }
    }, 500);
    // 30 秒后强制上报当前状态,告诉我们卡哪
    setTimeout(function () {
      clearInterval(splashWatch);
      send({
        source: 'lifecycle',
        message: 'discourse_boot_status_30s',
        stages: bootStages,
        hasSplash: !!document.querySelector('#d-splash'),
        url: location.href,
      });
    }, 30000);
  } catch (_) {}
  } // end isStubFrame else

  // ===== 2) console.error 拦截 — 突破跨域 sanitization =====
  try {
    var origConsoleError = console.error;
    console.error = function () {
      try {
        if (consoleErrCount < CONSOLE_ERR_MAX) {
          consoleErrCount++;
          var parts = [];
          var firstStack = null;
          for (var i = 0; i < arguments.length; i++) {
            var a = arguments[i];
            if (a instanceof Error) {
              parts.push(a.name + ': ' + (a.message || ''));
              if (!firstStack && a.stack) firstStack = a.stack;
            } else if (typeof a === 'string') {
              parts.push(a);
            } else {
              parts.push(safeStringify(a));
            }
          }
          send({
            source: 'console.error',
            message: parts.join(' '),
            stack: firstStack,
            url: location.href,
            ua: navigator.userAgent,
          });
        }
      } catch (_) {}
      return origConsoleError.apply(this, arguments);
    };
  } catch (_) {}

  // ===== 3) uncaught 错误兜底 =====
  window.addEventListener(
    'error',
    function (e) {
      if (!e) return;
      var err = e.error;
      var info = {
        source: 'window.error',
        message: e.message || (err && err.message) || null,
        filename: e.filename || null,
        lineno: e.lineno || null,
        colno: e.colno || null,
        stack: (err && err.stack) || null,
        url: location.href,
        ua: navigator.userAgent,
      };
      // sanitized 跨域错误兜底：所有字段都空，补上 target hint 用于定位是哪个资源
      if (!info.message && !info.filename && !info.stack) {
        info.message = '(sanitized cross-origin script error)';
        info.eventType = e.type || null;
        var target = e.target;
        if (target && target !== window && target.nodeType) {
          info.targetTag = target.tagName || null;
          info.targetSrc = target.src || target.href || null;
        }
      }
      reportError(info);
    },
    true,
  );

  window.addEventListener(
    'unhandledrejection',
    function (e) {
      var reason = e && e.reason;
      var msg = null;
      var stack = null;
      if (reason) {
        if (typeof reason === 'string') {
          msg = reason;
        } else if (reason.message) {
          msg = reason.message;
          stack = reason.stack || null;
        } else {
          msg = safeStringify(reason);
        }
      }
      reportError({
        source: 'unhandledrejection',
        message: msg,
        stack: stack,
        url: location.href,
        ua: navigator.userAgent,
      });
    },
    true,
  );
})();
