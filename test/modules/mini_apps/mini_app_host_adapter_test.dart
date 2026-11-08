import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_adapter.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runtime_surface.dart';

void main() {
  test('固定视口只适配官方隔离宿主，等待内层框架创建后停止观察', () async {
    final script = MiniAppHostAdapter.frameViewportScript(
      Uri.parse('https://linux.do/'),
    );
    final result = await Process.run('node', [
      '-e',
      '''
      const assert = require('node:assert/strict');
      const run = new Function('window', 'location', 'document', 'MutationObserver', ${jsonEncode(script)});
      const denied = new Proxy({}, {get() {throw Error('触及了非宿主文档');}});
      const top = {}; top.top = top;
      const child = {top};
      const location = {origin:'https://linux.do',pathname:'/mini-app-api/frame-host'};
      run(top, location, denied);
      run(child, {...location,origin:'https://other.test'}, denied);
      run(child, {...location,pathname:'/mini-app-api/production/app/runtime'}, denied);
      let mutation, disconnected = false, frame = null, count = 0;
      const element = () => ({rules:{},style:{setProperty(name,value,priority) {
        assert.equal(priority, 'important'); this[name] = value; count++;
      }}});
      const document = {documentElement:null,body:null,querySelector(selector) {
        assert.equal(selector, 'body > iframe'); return frame;
      }};
      class Observer {
        constructor(callback) {mutation = callback;}
        observe(target, options) {
          assert.equal(target, document); assert.equal(options.subtree, true);
        }
        disconnect() {disconnected = true;}
      }
      run(child, location, document, Observer);
      document.documentElement = element(); mutation();
      document.body = element(); mutation();
      assert.equal(disconnected, false);
      const fittedCount = count; mutation(); assert.equal(count, fittedCount);
      frame = element(); mutation();
      assert.equal(frame.style.height, '100%');
      assert.equal(document.body.style.overflow, 'hidden');
      assert.equal(disconnected, true);
      ''',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('声音状态探测不打开隐藏菜单或抢走选择框焦点', () async {
    final result = await Process.run('node', [
      '-e',
      '''
      const assert = require('node:assert/strict');
      const sound = new Function('document', 'toggle', ${jsonEncode('return (async () => {${MiniAppHostAdapter.soundOperation}})();')});
      const menu = {getAttribute: () => 'false', click() { throw Error('后台探测打开了菜单'); }};
      const header = {setAttribute() {}};
      const document = {
        documentElement: {setAttribute() {throw Error('后台探测修改了菜单状态');},removeAttribute() {}},
        activeElement: {isConnected:true,focus() {throw Error('后台探测抢走了焦点');}},
        querySelector(selector) {
          if (selector === '.mini-app-page__header') return header;
          if (selector === '.mini-app-page__more-trigger') return menu;
          return null;
        },
      };
      (async () => { assert.deepEqual(await sound(document, false), {available:false}); })()
        .catch(e => { console.error(e); process.exitCode = 1; });
      ''',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('官方授权后的 window.open 由主宿主接管，不依赖弹窗手势或泄漏到 iframe', () async {
    final signature = jsonEncode([
      'link-one',
      '应用请求操作',
      '打开链接',
      'https://hb.lafi.sh/tips',
      '取消',
      '允许',
    ]);
    final scripts = jsonEncode({
      'install': MiniAppHostAdapter.navigationScript(
        Uri.parse('https://linux.do/apps/example?embed_mode=true'),
      ),
      'snapshot': MiniAppHostAdapter.snapshot,
      'clear': MiniAppHostAdapter.clearExternalLinks,
      'allow': MiniAppHostAdapter.permissionOperation(signature, allow: true),
      'deny': MiniAppHostAdapter.permissionOperation(signature, allow: false),
    });
    final result = await Process.run('node', [
      '-e',
      '''const scripts = $scripts; $_navigationFixture''',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('权限提示必须包含完整的身份、用途和两个操作', () {
    expect(MiniAppPermissionRequest.parse({'action': '播放音频'}), isNull);
    expect(
      MiniAppPermissionRequest.parse({
        'signature': 'one',
        'title': '应用请求操作',
        'action': '播放音频',
        'notice': '',
        'reject': '静音进入',
        'allow': '开启声音',
      })?.action,
      '播放音频',
    );
  });

  test('宿主加载与权限适配拒绝过期请求、未知结构，不自动授予权限', () async {
    final signature = jsonEncode([
      'permission-one',
      'CS 请求操作',
      '播放音频',
      '本次运行可播放声音',
      '静音进入',
      '开启声音',
    ]);
    final scripts = jsonEncode({
      'snapshot': MiniAppHostAdapter.snapshot,
      'claim': MiniAppHostAdapter.permissionOperation(signature),
      'allow': MiniAppHostAdapter.permissionOperation(signature, allow: true),
      'deny': MiniAppHostAdapter.permissionOperation(signature, allow: false),
      'release': MiniAppHostAdapter.releasePermission,
      'retry': MiniAppHostAdapter.retry,
    });
    // 依据实际宿主 DOM 的固定夹具，执行生产脚本验证状态和真实按钮调用边界。
    final result = await Process.run('node', [
      '-e',
      '''
      const scripts = $scripts;
      const signature = ${jsonEncode(signature)};
      $_fixture
    ''',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}

const _navigationFixture = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
function host(href = 'https://linux.do/apps/example?embed_mode=true', frame = false) {
  const scope = {URL, location: new URL(href), document: {querySelector: () => null},
    open: () => { throw Error('没有 user activation 的原始弹窗调用'); }};
  scope.window = scope;
  scope.top = frame ? {} : scope;
  vm.createContext(scope);
  vm.runInContext(scripts.install, scope);
  return scope;
}
for (const scope of [host(undefined, true), host('https://evil.test/apps/example'),
  host('https://linux.do/apps/other')]) {
  assert.equal(scope.fluxdoMiniAppLinks, undefined);
}
const scope = host();
const links = scope.fluxdoMiniAppLinks;
let dialogOpen = false, resolvePermission;
const title = {id: 'link-one', textContent: '应用请求操作'};
const paragraphs = [{textContent: '打开链接'}, {textContent: 'https://hb.lafi.sh/tips'}];
const buttons = ['取消', '允许'].map((textContent, index) => ({textContent, disabled: false,
  classList: {contains: name => index === 1 && name === '--primary'},
  click: () => { dialogOpen = false; resolvePermission(index === 1); }
}));
const dialog = {querySelector: () => title,
  querySelectorAll: selector => selector === 'p' ? paragraphs : buttons,
  removeAttribute: () => {}};
scope.document.querySelector = selector =>
  selector === 'dialog.mini-app-permission-dialog[open]' && dialogOpen ? dialog : null;
const peek = () => vm.runInContext(scripts.snapshot, scope).externalLink;
vm.runInContext(scripts.install, scope); // 重复安装不会覆盖未完成的请求
assert.equal(scope.fluxdoMiniAppLinks, links);
for (const target of ['', 'javascript:alert(1)', 'data:text/html,test',
  'file:///private', 'blob:https://linux.do/id', 'https://me@evil.test/']) {
  scope.open(target);
  assert.equal(peek(), null);
}
(async () => {
  // 对应已核对的官方 links.open：确认 Promise 通过之后执行
  // view.open(url, '_blank', 'noopener,noreferrer')，没有浏览器原生手势。
  async function officialOpen() {
    const allowed = await new Promise(resolve => { dialogOpen = true; resolvePermission = resolve; });
    if (allowed) scope.open('https://hb.lafi.sh/tips', '_blank', 'noopener,noreferrer');
  }
  let operation = officialOpen();
  assert.equal(peek(), null);
  assert.equal(vm.runInContext(scripts.deny, scope), true);
  await operation;
  assert.equal(peek(), null);
  operation = officialOpen();
  title.id = 'changed';
  assert.equal(vm.runInContext(scripts.allow, scope), false);
  assert.equal(peek(), null);
  title.id = 'link-one';
  assert.equal(vm.runInContext(scripts.allow, scope), true);
  await operation;
  const request = peek();
  assert.equal(request.url, 'https://hb.lafi.sh/tips');
  scope.open('https://other.test');
  assert.equal(peek(), request); // 同一确认周期不排队
  assert.equal(links.take('old-document'), false);
  assert.equal(links.take(request.id), true);
  assert.equal(links.take(request.id), false);
  assert.equal(peek(), null);
  scope.open('https://other.test');
  assert.equal(peek(), null); // 确认框存在期间不重复打开
  links.finish('old-document');
  scope.open('https://other.test');
  assert.equal(peek(), null);
  links.finish(request.id);
  operation = officialOpen();
  assert.equal(vm.runInContext(scripts.allow, scope), true);
  await operation;
  assert.notEqual(peek().id, request.id); // 用户可以再次主动打开同一网址
  vm.runInContext(scripts.clear, scope);
  assert.equal(peek(), null);
  scope.open('/t/example/1', '_self');
  assert.equal(peek().url, 'https://linux.do/t/example/1');
  assert.equal(host().fluxdoMiniAppLinks.peek(), null); // 刷新不继承请求
})().catch(error => { console.error(error); process.exitCode = 1; });
''';

const _fixture = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
let open = true, hidden = false, calls = [], retries = 0;
const title = {id: 'permission-one', textContent: 'CS 请求操作'};
const paragraphs = [{textContent: '播放音频'}, {textContent: '本次运行可播放声音'}];
const buttons = ['静音进入', '开启声音'].map((textContent, index) => ({
  textContent, disabled: false,
  classList: {contains: name => index === 1 && name === '--primary'},
  click: () => { calls.push(index); open = false; }
}));
const dialog = {
  querySelector: selector => selector === 'h2' ? title : null,
  querySelectorAll: selector => selector === 'p' ? paragraphs : buttons,
  setAttribute: () => hidden = true,
  removeAttribute: () => hidden = false,
};
const retry = {hidden: true, disabled: false, click: () => retries++};
const progress = {max: 20, value: 4, hasAttribute: () => true};
const loading = {hidden: false, querySelector: selector => ({
  'progress': progress, '[data-role="stage"]': {textContent:'下载应用包'},
  '[data-role="detail"]': {textContent: '4 / 20 KiB'}, '[data-action="retry"]': retry,
})[selector]};
const loader = {querySelector: selector => selector === 'iframe' ? {} : loading};
const document = {
  fullscreenElement: null,
  querySelector: selector => ({
    '.mini-app-page__header': {hasAttribute: () => false},
    '.mini-app-loader': loader,
    'dialog.mini-app-permission-dialog[open]': open ? dialog : null,
    '.mini-app-loader__loading [data-action="retry"]': retry,
  })[selector] || null,
  querySelectorAll: () => hidden ? [dialog] : [],
};
const run = name => vm.runInNewContext(scripts[name], {document});
assert.equal(run('snapshot').ready, false); // frame 创建不代表游戏已就绪
assert.equal(run('snapshot').progress, .2);
assert.equal(run('snapshot').permission.signature, signature);
assert.equal(run('claim'), true);
assert.equal(hidden, true);
assert.deepEqual(calls, []); // 仅呈现权限 UI，不能隐式同意
run('release');
assert.equal(hidden, false);
run('claim');
title.id = 'permission-two';
assert.equal(run('allow'), false); // 原按钮不应授权新请求
assert.deepEqual(calls, []);
run('release');
title.id = 'permission-one';
paragraphs[1].textContent = '用途已经改变';
assert.equal(run('allow'), false);
paragraphs[1].textContent = '本次运行可播放声音';
assert.equal(run('deny'), true);
assert.deepEqual(calls, [0]);
assert.equal(hidden, false);
open = true;
assert.equal(run('allow'), true);
assert.deepEqual(calls, [0, 1]);
open = true;
buttons.push(buttons[0]);
assert.equal(run('snapshot').permission, null);
assert.equal(run('snapshot').webPermission, true);
assert.equal(run('claim'), false);
assert.equal(run('retry'), false);
retry.hidden = false;
assert.equal(run('retry'), true);
assert.equal(retries, 1);
loading.hidden = true;
assert.equal(run('snapshot').ready, true);
''';
