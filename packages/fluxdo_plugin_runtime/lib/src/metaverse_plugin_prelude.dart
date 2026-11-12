/// 注入到每个插件脚本环境的前导脚本：定义全局 `fluxdo` SDK。
///
/// 这里只是便利封装，不是安全边界——插件与它在同一个 JS 环境里，可以绕过
/// SDK 直接发消息。所有权限检查都在 Dart 侧（`MetaversePluginRuntime` 与
/// `MetaversePluginHost`）。
///
/// 覆盖 flutter_js 自带的 `setTimeout`/`console`：自带的定时器不受宿主
/// 管理，引擎释放后仍会回调。
const metaversePluginPrelude = r'''
(function () {
  'use strict';
  var send = globalThis.sendMessage;
  var CHANNEL = 'fluxdoMetaverse';
  var seq = 0, pending = {}, handlers = {}, timers = {}, timerSeq = 0;

  function post(message) { send(CHANNEL, JSON.stringify(message)); }

  function request(method, params, surface) {
    return new Promise(function (resolve, reject) {
      var id = ++seq;
      pending[id] = { resolve: resolve, reject: reject };
      post({ t: 'call', id: id, m: method, s: surface, p: params === undefined ? null : params });
    });
  }

  function report(where, error) {
    post({
      t: 'error',
      where: String(where),
      message: String((error && error.message) || error),
      stack: String((error && error.stack) || '')
    });
  }

  function text(value) {
    if (typeof value === 'string') return value;
    if (value instanceof Error) return value.message;
    try { return JSON.stringify(value); } catch (e) { return String(value); }
  }

  function logger(level) {
    return function () {
      post({ t: 'log', level: level, message: Array.prototype.map.call(arguments, text).join(' ') });
    };
  }

  function makeContext(info) {
    return Object.freeze({
      surface: info.surface,
      kind: info.kind,
      page: info.page || null,
      params: info.params || {},
      api: makeApi(info.surface),
      setData: function (key, value) {
        post({ t: 'data', s: info.surface, k: String(key), v: value === undefined ? null : value });
      }
    });
  }

  globalThis.console = Object.freeze({
    log: logger('info'), info: logger('info'), debug: logger('info'),
    warn: logger('warn'), error: logger('error')
  });

  globalThis.setTimeout = function (fn, ms) {
    if (typeof fn !== 'function') return 0;
    var id = ++timerSeq;
    var args = Array.prototype.slice.call(arguments, 2);
    timers[id] = function () { fn.apply(null, args); };
    post({ t: 'timer', op: 'set', id: id, ms: Number(ms) || 0 });
    return id;
  };

  globalThis.clearTimeout = function (id) {
    if (!timers[id]) return;
    delete timers[id];
    post({ t: 'timer', op: 'clear', id: id });
  };

  function makeApi(surface) {
    function call(method, params) { return request(method, params, surface); }
    return Object.freeze({
    /** 注册事件处理器：card.load / page.open / page.hide / page.resume / surface.close，或界面声明的事件。 */
    on: function (name, handler) { handlers[String(name)] = handler; },

    /** 发起网络请求，目标域名须在清单 permissions.network 内。 */
    fetch: function (url, options) {
      options = options || {};
      var body = options.body;
      var headers = Object.assign({}, options.headers || {});
      if (body !== undefined && body !== null && typeof body !== 'string') {
        body = JSON.stringify(body);
        if (!Object.keys(headers).some(function (k) { return k.toLowerCase() === 'content-type'; })) {
          headers['Content-Type'] = 'application/json';
        }
      }
      return call('fetch', {
        url: String(url),
        method: options.method || 'GET',
        headers: headers,
        body: body === undefined ? null : body,
        auth: options.auth === true
      }).then(function (response) {
        response.ok = response.status >= 200 && response.status < 300;
        response.json = function () { return JSON.parse(response.body); };
        return response;
      });
    },

    storage: Object.freeze({
      get: function (key) { return call('storage.get', { key: String(key) }); },
      set: function (key, value) { return call('storage.set', { key: String(key), value: value === undefined ? null : value }); },
      remove: function (key) { return call('storage.remove', { key: String(key) }); }
    }),

    auth: Object.freeze({
      query: function (name, args) { return call('auth.query', {name:name, arguments:args}).then(function (res) {
        res.ok = res.status >= 200 && res.status < 300;
        res.json = function () { return JSON.parse(res.body); };
        return res;
      }); },
      status: function () { return call('auth.status'); },
      request: function () { return call('auth.request'); },
      signOut: function () { return call('auth.signOut'); }
    }),

    checkout: Object.freeze({
      pay: function (no) { return call('checkout.pay',{orderNo:no}); },
      cancel: function (no) { return call('checkout.cancel',{orderNo:no}); },
      status: function () { return call('checkout.status'); },
      submit: function (intent) { return call('checkout.submit',intent); },
      recover: function () { return call('checkout.recover'); },
      retry: function () { return call('checkout.retry'); },
      finish: function (no) { return call('checkout.finish',{orderNo:no}); }
    }),
    user: Object.freeze({
      get: function () { return call('user.get'); }
    }),

    navigate: function (page, params) { return call('navigate', { page: String(page), params: params || {} }); },
    /** 在用户点击时预约一次页面导航，用于异步操作成功后的跳转。 */
    prepareNavigation: function (page) {
      page = String(page);
      return call('navigation.prepare', {page: page}).then(function (token) {
        return function (params) {
          return call('navigate', {page: page, params: params || {}, continuation: token});
        };
      });
    },
    session: Object.freeze({
      login: function () { return call('session.login'); },
      open: function (path) { return call('session.open', { path: String(path) }); }
    }),
    openUrl: function (url) { return call('openUrl', { url: String(url) }); },
    toast: function (message, type) { return call('toast', { message: String(message), type: type || 'info' }); }
    });
  }
  globalThis.fluxdo = makeApi(null);

  Object.defineProperty(globalThis, '__fluxdoMetaverse', {
    value: Object.freeze({
      settle: function (id, ok, json) {
        var entry = pending[id];
        if (!entry) return;
        delete pending[id];
        var value = JSON.parse(json);
        if (ok) entry.resolve(value); else entry.reject(new Error(String(value)));
      },
      dispatch: function (name, infoJson, argsJson) {
        var handler = handlers[name];
        if (typeof handler !== 'function') return false;
        try {
          var result = handler(makeContext(JSON.parse(infoJson)), JSON.parse(argsJson));
          if (result && typeof result.then === 'function') {
            result.then(null, function (error) { report(name, error); });
          }
        } catch (error) {
          report(name, error);
        }
        return true;
      },
      timer: function (id) {
        var fn = timers[id];
        if (!fn) return;
        delete timers[id];
        try { fn(); } catch (error) { report('setTimeout', error); }
      }
    })
  });
})();
''';
