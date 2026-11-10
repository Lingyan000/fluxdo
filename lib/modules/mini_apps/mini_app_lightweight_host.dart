import 'dart:convert';

import 'mini_app.dart';
import 'mini_app_host_adapter.dart';
import 'mini_app_url.dart';

/// 只生成可信宿主外壳。授权、包处理、权限和应用隔离继续由官方加载器执行。
abstract final class MiniAppLightweightHost {
  static String build({
    required MiniAppDetails details,
    required Uri entry,
    required String site,
    required String background,
    required String foreground,
    required String primary,
    required String failureMessage,
    required String preparingMessage,
    int? expectedUserId,
  }) {
    final checked = MiniAppUrl.embed(entry.toString(), details.app.id, site);
    final base = Uri.parse(site);
    if (checked != entry || base.scheme != 'https') {
      throw const FormatException('Invalid lightweight host origin');
    }
    final prefix = base.path.replaceFirst(RegExp(r'/$'), '');
    final config = Map<String, dynamic>.from(details.configuration);
    if (config['appId'] != details.app.id ||
        config['channel'] != 'production') {
      throw const FormatException('Invalid lightweight host configuration');
    }
    for (final action in [
      'launch',
      'check',
      'runtime',
      'usage',
      'http-authorization',
      'websocket-authorization',
    ]) {
      final key = switch (action) {
        'http-authorization' => 'httpAuthorizationUrl',
        'websocket-authorization' => 'webSocketAuthorizationUrl',
        _ => '${action}Url',
      };
      config[key] = _url(
        base,
        config[key],
        '$prefix/mini-app-api/production/${details.app.id}/$action',
      );
    }
    config['frameHostUrl'] = _url(
      base,
      config['frameHostUrl'],
      '$prefix/mini-app-api/frame-host',
    );
    for (final color in [background, foreground, primary]) {
      if (!RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(color)) {
        throw const FormatException('Invalid host theme');
      }
    }
    final boot = _json({
      'configuration': config,
      'entry': entry.toString(),
      'prefix': prefix,
      'expectedUserId': expectedUserId,
      'failureMessage': failureMessage,
    });
    final escape = const HtmlEscape().convert;
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="csrf-token" content="">
<meta http-equiv="Content-Security-Policy" content="object-src 'none'; base-uri 'none'">
<title>${escape(details.app.name)}</title>
<style>
${MiniAppHostAdapter.css}
:root { color-scheme: light dark; background:$background; color:$foreground;
  --tertiary:$primary; --primary-low:$foreground; font-family:system-ui,sans-serif; }
.mini-app-page,.mini-app-loader { background:$background; color:$foreground; }
.mini-app-loader__loading { padding:24px; display:flex; flex-direction:column; gap:16px; }
.mini-app-loader__loading[hidden] { display:none; }
.mini-app-permission-dialog { border:0; border-radius:24px; padding:24px;
  background:$background; color:$foreground; max-width:min(440px,85vw); }
.mini-app-permission-dialog button { padding:12px; margin:6px; }
</style></head><body>
<main class="mini-app-page" data-fluxdo-engine="lightweight">
<header class="mini-app-page__header"><button class="mini-app-page__audio-trigger"
  type="button" aria-pressed="false" disabled></button></header>
<section class="mini-app-loader is-loading"><div class="mini-app-loader__viewport">
<div class="mini-app-loader__loading"><strong data-role="stage">${escape(preparingMessage)}</strong>
<progress></progress><span data-role="detail"></span>
<button type="button" data-action="retry" hidden>Retry</button></div>
<div class="mini-app-loader__frame" inert></div></div><div class="mini-app-loader__media"></div>
</section></main><script type="application/json" id="fluxdo-mini-app-release"></script>
<script type="application/json" id="fluxdo-mini-app-boot-failure"></script>
<script>const boot = $boot;
$script
</script></body></html>''';
  }

  static String _url(Uri base, Object? value, String path) {
    if (value is! String || value.contains('\\')) {
      throw const FormatException('Missing runtime URL');
    }
    final uri = base.resolve(value);
    if (uri.origin != base.origin ||
        uri.path != path ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Invalid runtime URL');
    }
    return uri.toString();
  }

  static String _json(Object value) =>
      jsonEncode(value)
          .replaceAll('<', r'\u003c')
          .replaceAll('>', r'\u003e')
          .replaceAll('&', r'\u0026')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');

  /// Windows 的插件目前把所有请求标为主 frame，还要核对 Fetch Metadata。
  /// 仅替换精确的入口文档；包、API、worker 和 frame-host 完全走原网络路径。
  static bool intercepts({
    required Uri entry,
    required Uri request,
    required String? method,
    required bool? mainFrame,
    Map<String, String>? headers,
  }) {
    if (method != 'GET' ||
        mainFrame != true ||
        request.replace(fragment: '') != entry.replace(fragment: '')) {
      return false;
    }
    final destination = headers?.entries
        .where((e) => e.key.toLowerCase() == 'sec-fetch-dest')
        .firstOrNull
        ?.value;
    return destination == null || destination == 'document';
  }

  static const script = r'''
(() => {
  'use strict';
  const root = document.querySelector('.mini-app-loader');
  const loading = root.querySelector('.mini-app-loader__loading');
  const audio = document.querySelector('.mini-app-page__audio-trigger');
  const lifetime = new AbortController();
  let runtime, provider, muted = true, closed = false;
  let phase = 'environment';
  let suspended = false, resumeMuted = true, mediaQueue = Promise.resolve();
  function setSuspended(value) {
    // 仅主宿主可调用；保留用户原先的声音选择，快速收起/恢复按顺序执行。
    mediaQueue = mediaQueue.catch(() => {}).then(async () => {
      if (closed || suspended === value) return;
      if (value) resumeMuted = muted;
      suspended = value;
      if (runtime) await runtime.setAudioMuted(value || resumeMuted);
    });
    return mediaQueue.catch(() => {});
  }
  const invalid = code => Object.assign(new Error(code), {code});
  function active() { if (closed || lifetime.signal.aborted) throw invalid('APP_UNLOADED'); }
  function destroy() {
    if (closed) return;
    closed = true;
    lifetime.abort();
    runtime?.destroy();
    provider?.destroy();
    runtime = provider = null;
  }
  window.addEventListener('pagehide', destroy, {once:true});
  // 由原生关闭/切换前调用，不提供应用沙箱可调用的原生网络桥。
  Object.defineProperty(window, 'fluxdoMiniAppHost', {
    value: Object.freeze({destroy, setSuspended}), configurable:false, writable:false,
  });
  function asset(value, kind, worker = false, extension = 'js') {
    if (typeof value !== 'string' || value.includes('\\')) throw invalid('INVALID_RUNTIME_ASSET');
    const url = new URL(value, location.origin);
    const stem = boot.prefix + (worker ? '/mini-app-api/workers/' : '/plugins/discourse-mini-app/runtime/');
    if (url.origin !== location.origin || url.username || url.password || url.search || url.hash ||
        !url.pathname.startsWith(stem) ||
        !(new RegExp('^' + kind + '-[a-f0-9]{64}\\.' + extension + '$')).test(url.pathname.slice(stem.length))) {
      throw invalid('INVALID_RUNTIME_ASSET');
    }
    return url.href;
  }
  async function json(path, signal = lifetime.signal) {
    const requestPhase = path === '/mini-app-api/runtime-assets.json' ? 'runtime_assets' :
      path === '/session/current.json' ? 'session' : path === '/session/csrf' ? 'csrf' : 'user';
    try {
      active();
      const response = await fetch(boot.prefix + path, {
        credentials:'same-origin', cache:'no-store', redirect:'error',
        headers:{'X-Requested-With':'XMLHttpRequest'},
        signal:AbortSignal.any([signal, lifetime.signal, AbortSignal.timeout(20000)]),
      });
      active();
      if (!response.ok) throw Object.assign(invalid(
        response.status === 401 || response.status === 403 ? 'ACCESS_DENIED' : 'REQUEST_FAILED'),
        {status:response.status});
      return await response.json();
    } catch (error) {
      // 不记录请求地址、响应正文或异常 message；它们可能含启动参数与凭据。
      throw {code:error?.code, name:error?.name, status:error?.status, phase:requestPhase};
    }
  }
  function fail(error) {
    if (closed) return;
    runtime?.destroy();
    provider?.destroy();
    runtime = provider = null;
    root.classList.remove('is-loading');
    root.classList.add('is-error');
    loading.hidden = false;
    loading.querySelector('progress').hidden = true;
    root.querySelector('[data-role="stage"]').textContent = boot.failureMessage;
    const code = ['ACCESS_DENIED','BROWSER_UNSUPPORTED','INVALID_RUNTIME_ASSET',
      'INVALID_USER','REQUEST_FAILED'].includes(error?.code) ? error.code : 'START_FAILED';
    const expected = new URL(boot.entry);
    const diagnostic = {
      appId:boot.configuration.appId, code, phase:error?.phase || phase,
      errorName:error?.name, httpStatus:error?.status,
      secureContext:isSecureContext, sameOrigin:location.origin === expected.origin,
      entryMatches:location.href === expected.href,
    };
    document.getElementById('fluxdo-mini-app-boot-failure').textContent = JSON.stringify(diagnostic);
    root.querySelector('[data-role="detail"]').textContent =
      (boot.configuration.translations?.errors?.[code] || code) + '\n' +
      '[' + diagnostic.phase + (Number.isInteger(diagnostic.httpStatus) ?
        ' · HTTP ' + diagnostic.httpStatus : '') +
      (['TypeError','SyntaxError','ReferenceError','SecurityError','AbortError','TimeoutError',
        'NotSupportedError'].includes(diagnostic.errorName) ? ' · ' + diagnostic.errorName : '') + ']';
    root.querySelector('[data-action="retry"]').hidden = false;
  }
  async function start() {
    const expected = new URL(boot.entry);
    if (!isSecureContext || location.origin !== expected.origin) throw invalid('BROWSER_UNSUPPORTED');
    // WKWebView 的 HTML 加载保留源，但可能忽略查询/锚点；恢复本次启动参数。
    if (location.href !== expected.href) history.replaceState(null, '', expected.href);
    if (location.href !== expected.href) throw invalid('BROWSER_UNSUPPORTED');
    phase = 'bootstrap';
    const config = {...boot.configuration};
    const anonymous = config.anonymous === true;
    const assetsPromise = json('/mini-app-api/runtime-assets.json');
    const sessionPromise = anonymous ? Promise.resolve(null) : json('/session/current.json');
    const csrfPromise = anonymous ? Promise.resolve(null) : json('/session/csrf');
    const [assets, session, csrf] = await Promise.all([assetsPromise, sessionPromise, csrfPromise]);
    active();
    phase = 'identity';
    const current = anonymous ? null : session?.current_user;
    if (!anonymous && (!Number.isSafeInteger(current?.id) ||
        typeof current?.username !== 'string' ||
        (boot.expectedUserId != null && current.id !== boot.expectedUserId))) throw invalid('INVALID_USER');
    if (!anonymous && (typeof csrf?.csrf !== 'string' || !csrf.csrf)) throw invalid('ACCESS_DENIED');
    document.querySelector('meta[name="csrf-token"]').content = csrf?.csrf || '';
    phase = 'runtime_assets';
    for (const key of ['runtimeAssets','sdkUrl','sdkSha256','sdkFallbackUrl','sdkByteLength']) {
      if (Object.hasOwn(assets, key)) config[key] = assets[key];
    }
    const runtimeAssets = config.runtimeAssets;
    const loaderUrl = asset(runtimeAssets?.loader, 'loader');
    asset(runtimeAssets?.packageWorker, 'package-worker', true);
    asset(runtimeAssets?.preflightWorker, 'package-preflight-worker', true);
    for (const [key, kind] of [['frameHostStyle','frame-host'],['errorStyle','error']]) {
      const link = document.createElement('link');
      link.rel = 'stylesheet'; link.href = asset(runtimeAssets?.[key], kind, false, 'css');
      document.head.append(link);
    }
    phase = 'loader_import';
    const loader = await import(loaderUrl);
    active();
    if (typeof loader.mountLoader !== 'function' || typeof loader.createUserDataProvider !== 'function') {
      throw invalid('INVALID_RUNTIME_ASSET');
    }
    phase = 'loader_mount';
    provider = loader.createUserDataProvider({
      getCurrentUser: () => { active(); return current; },
      isActive: () => !closed,
      findById: async (id, signal) => {
        if (!Number.isSafeInteger(id) || id === 0) throw invalid('INVALID_ARGUMENTS');
        if (id === current?.id) return current;
        const data = await json('/user-cards.json?user_ids=' + encodeURIComponent(String(id)), signal);
        if (!Array.isArray(data?.users)) throw invalid('INVALID_RESPONSE');
        return data.users.find(user => user?.id === id) || null;
      },
      getAvatarUrl: user => {
        if (typeof user?.avatar_template !== 'string') return null;
        const url = new URL(user.avatar_template.replaceAll('{size}','288'), location.origin);
        return url.protocol === 'https:' && !url.username && !url.password ? url.href : null;
      },
    });
    // 官方 SDK 在沙箱内只接收有限用户字段和已读取的头像，不传入论坛凭据。
    const userProvider = {
      ...provider,
      loadAvatar: async (url, signal) => {
        const parsed = new URL(url);
        if (parsed.protocol !== 'https:' || parsed.username || parsed.password) return null;
        const combined = AbortSignal.any([signal, lifetime.signal, AbortSignal.timeout(10000)]);
        const response = await fetch(parsed.href, {credentials:'omit', mode:'cors',
          cache:'force-cache', redirect:'error', referrerPolicy:'no-referrer', signal:combined});
        const mime = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
        if (!response.ok || !/^image\/(png|jpeg|gif|webp|avif)$/.test(mime || '') || !response.body) return null;
        const reader = response.body.getReader(), chunks = [];
        let size = 0;
        try {
          for (;;) {
            const {done,value} = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > 4 * 1024 * 1024) return null;
            chunks.push(value);
          }
        } finally { await reader.cancel().catch(() => {}); }
        active();
        return new Promise((resolve, reject) => {
          const reader = new FileReader();
          const abort = () => { reader.abort(); reject(invalid('APP_UNLOADED')); };
          combined.addEventListener('abort', abort, {once:true});
          reader.onloadend = () => {
            combined.removeEventListener('abort', abort);
            resolve(typeof reader.result === 'string' ? reader.result : null);
          };
          if (combined.aborted) abort();
          else reader.readAsDataURL(new Blob(chunks, {type:mime}));
        });
      },
    };
    runtime = loader.mountLoader(root, {
      ...config, userProvider, fullscreenElement:document.querySelector('.mini-app-page'),
      onAudioStateChange: value => {
        if (closed) return;
        audio.disabled = value === null;
        if (typeof value === 'boolean') {
          muted = value; audio.setAttribute('aria-pressed', String(!muted));
        }
      },
      onRelease: release => {
        if (closed || release?.app_id !== config.appId) return;
        const safe = {};
        for (const key of ['app_id','id','version','channel','name','description','icon_url','release_notes']) {
          if (typeof release[key] === 'string' || typeof release[key] === 'number') safe[key] = release[key];
        }
        document.getElementById('fluxdo-mini-app-release').textContent = JSON.stringify(safe);
      },
    });
    document.querySelector('.mini-app-page').setAttribute('data-fluxdo-mounted', '');
    if (suspended) runtime.setAudioMuted(true).catch(() => {});
    audio.addEventListener('click', async () => {
      if (closed || audio.disabled || !runtime) return;
      audio.disabled = true;
      try { await runtime.setAudioMuted(!muted); }
      catch { /* 保留官方实际声音状态；原生层会报告切换未成功。 */ }
      finally { if (!closed) audio.disabled = false; }
    }, {signal:lifetime.signal});
  }
  start().catch(fail);
})();
''';
}
