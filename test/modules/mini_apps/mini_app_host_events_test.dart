import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_events.dart';

void main() {
  for (final lightweight in [false, true]) {
    test('两套宿主共用首屏等待、状态通知与重绑取消 ($lightweight)', () async {
      final entry = Uri.parse('https://linux.do/apps/example?embed_mode=true');
      final result = await Process.run('node', [
        '-e',
        '''const script = ${jsonEncode(MiniAppHostEvents.install(entry, 'first'))};
      const reconnect = ${jsonEncode(MiniAppHostEvents.install(entry, 'second'))};
      const lightweight = $lightweight;
      $_fixture''',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });
  }
}

const _fixture = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
const settle = async () => { for(let i=0;i<6;i++) await new Promise(setImmediate); };
const timers = new Map(), messages = [], observers = [], listeners = {};
const frames = new Map();
let nextTimer = 0, nextFrame = 0, response, frame = {};
const stage = {textContent:'下载'}, loading = {hidden:false,
  querySelector:selector=>selector==='[data-role="stage"]'?stage:null};
const loader = {querySelector:selector=>selector==='.mini-app-loader__loading'?loading:
  selector==='iframe'?frame:null};
const header = {hasAttribute:()=>false}, page = {hasAttribute:()=>lightweight};
const document = {documentElement:{},
  getElementById:()=>null,
  querySelector:selector=>({'.mini-app-page__header':header,'.mini-app-loader':loader,
    '.mini-app-page':page})[selector] || null,
  addEventListener:(name,callback)=>listeners[name]=callback,
};
class Observer {
  constructor(callback) { this.callback=callback; observers.push(this); }
  observe() {}
  disconnect() { this.disconnected=true; }
}
const context = vm.createContext({document,location:new URL('https://linux.do/apps/example'),
  AbortController, MutationObserver:Observer, PerformanceObserver:Observer,
  performance:{getEntriesByName:()=>[{startTime:10,detail:{status:'ready'}}]},
  setTimeout:callback=>{timers.set(++nextTimer,callback);return nextTimer;},
  clearTimeout:id=>timers.delete(id),
  requestAnimationFrame:callback=>{frames.set(++nextFrame,callback);return nextFrame;},
  cancelAnimationFrame:id=>frames.delete(id),
  addEventListener:(name,callback)=>listeners[name]=callback,
  flutter_inappwebview:{callHandler:(name,message)=>{
    assert.equal(name,'fluxdoMiniAppState'); messages.push(message);
    return new Promise(resolve=>response=resolve);
  }},
});
context.window=context; context.top=context;
function tick() { const callbacks=[...timers.values()];timers.clear();callbacks.forEach(fn=>fn()); }
function paint() { const callbacks=[...frames.values()];frames.clear();callbacks.forEach(fn=>fn()); }
(async()=>{
  assert.equal(vm.runInContext(script,context).loading,true);
  tick(); assert.equal(messages.length,1);
  assert.equal(messages[0].state.loading,true);
  assert.equal(messages[0].token,'first');
  loading.hidden=true;
  stage.textContent='准备首屏';
  for(let i=0;i<100;i++) observers[0].callback();
  tick();assert.equal(messages.length,1,'一个消息确认前只保留最新状态');
  response(true);await settle();tick();
  assert.equal(messages.length,2);
  assert.equal(messages[1].state.ready,false,'等待应用完成绘制');
  assert.equal(messages[1].state.performance,null,'首屏绘制完成前不报告启动结束');
  paint();assert.equal(context.fluxdoMiniAppEvents.renderedFrame,null);
  paint();assert.equal(context.fluxdoMiniAppEvents.renderedFrame,frame);
  response(true);await settle();tick();
  assert.equal(messages.length,3);
  assert.equal(messages[2].state.ready,true);
  assert.equal(messages[2].state.performance.status,'ready');
  response(true);await settle();
  context.fluxdoMiniAppEvents.notify();tick();assert.equal(messages.length,3,'相同状态不重复上报');
  const previous=observers.slice();
  assert.equal(vm.runInContext(reconnect,context).ready,true,'同一文档重新挂载保留已绘制首屏');
  assert.ok(previous.every(observer=>observer.disconnected));
  tick();assert.equal(messages.at(-1).token,'second');
  response(true);await settle();
  loading.hidden=false;context.fluxdoMiniAppEvents.notify();tick();
  assert.equal(messages.at(-1).state.ready,false);
  response(true);await settle();
  loading.hidden=true;frame={};context.fluxdoMiniAppEvents.notify();tick();
  assert.equal(messages.at(-1).state.ready,false,'重试产生的新 frame 重新等待绘制');
  paint();
  listeners.pagehide();response(true);await settle();
  paint();assert.equal(context.fluxdoMiniAppEvents.renderedFrame,null,'关闭取消迟到的绘制回调');
  const count=messages.length;
  observers.forEach(observer=>observer.callback());tick();
  assert.equal(messages.length,count,'页面关闭后的回调不继续发送');
  delete context.flutter_inappwebview;
  assert.equal(vm.runInContext(script,context).ready,false);
  paint();paint();tick();
  assert.equal(context.fluxdoMiniAppEvents.renderedFrame,frame,'桥接不可用时轮询仍能读取就绪状态');
  context.fluxdoMiniAppEvents.dispose();
  context.window={top:{}};
  assert.equal(vm.runInContext(script,context),false,'子 frame 不能安装通知桥');
})().catch(error=>{console.error(error);process.exitCode=1;});
''';
