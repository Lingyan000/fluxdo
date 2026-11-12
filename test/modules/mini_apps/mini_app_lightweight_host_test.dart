import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_engine.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_lightweight_host.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_launch_report.dart';

const id = '01a1b02d-04ed-7342-baa5-769b244b7b9a';
const site = 'https://linux.do';
final entry = Uri.parse('$site/apps/$id?embed_mode=true&room=42#invite');
final configuration = <String, dynamic>{
  'appId': id,
  'channel': 'production',
  'anonymous': false,
  'frameHostUrl': '/mini-app-api/frame-host',
  for (final action in ['launch', 'check', 'runtime', 'usage'])
    '${action}Url': '/mini-app-api/production/$id/$action',
  'httpAuthorizationUrl': '/mini-app-api/production/$id/http-authorization',
  'webSocketAuthorizationUrl':
      '/mini-app-api/production/$id/websocket-authorization',
};

void main() {
  test('轻量外壳保留启动参数、转义配置，拒绝错误应用和跨源授权地址', () {
    String build(Map<String, dynamic> config) => MiniAppLightweightHost.build(
      details: MiniAppDetails(
        const MiniApp(id: id, name: '</script><script>bad()</script>'),
        entry.toString(),
        configuration: config,
      ),
      entry: entry,
      site: site,
      background: '#ffffff',
      foreground: '#111111',
      primary: '#123456',
      failureMessage: '失败',
      preparingMessage: '准备',
    );
    final html = build({
      ...configuration,
      'name': '</script><script>bad()</script>',
    });
    expect(html, isNot(contains('<script>bad()')));
    expect(html, contains(r'\u003c/script\u003e'));
    expect(html, contains('room=42'));
    expect(html, contains('#invite'));
    expect(
      () => build({...configuration, 'appId': 'wrong'}),
      throwsFormatException,
    );
    expect(
      () =>
          build({...configuration, 'launchUrl': 'https://evil.example/launch'}),
      throwsFormatException,
    );
    expect(
      () => build({
        ...configuration,
        'usageUrl': '/mini-app-api/production/$id/usage?token=x',
      }),
      throwsFormatException,
    );
  });

  test('仅拦截入口主文档，不拦截 API、iframe、脚本、其他应用或其他查询参数', () {
    bool allowed(
      String url, {
      String method = 'GET',
      bool main = true,
      String? destination,
    }) => MiniAppLightweightHost.intercepts(
      entry: entry,
      request: Uri.parse(url),
      method: method,
      mainFrame: main,
      headers: destination == null ? null : {'Sec-Fetch-Dest': destination},
    );
    expect(
      allowed(entry.replace(fragment: '').toString(), destination: 'document'),
      isTrue,
    );
    expect(allowed(entry.toString(), method: 'POST'), isFalse);
    expect(allowed(entry.toString(), main: false), isFalse);
    expect(allowed(entry.toString(), destination: 'iframe'), isFalse);
    expect(allowed(entry.toString(), destination: 'empty'), isFalse);
    expect(allowed('$site/apps/$id?embed_mode=true'), isFalse);
    expect(allowed('$site/mini-app-api/frame-host'), isFalse);
    expect(allowed('$site/mini-app-api/production/$id/launch'), isFalse);
    expect(
      allowed('https://evil.example/apps/$id?embed_mode=true&room=42'),
      isFalse,
    );
  });

  test('计时只保留来源和受限数值，不落盘令牌或任意页面字段', () {
    final report = MiniAppLaunchReport.parse({
      'appId': id,
      'status': 'ready',
      'startTime': 20,
      'duration': 100,
      'packageSource': 'persistent',
      'runtime_token': 'secret',
      'package_password': 'secret',
      'phases': {
        'download': double.nan,
        'unpack': 35,
        'audio_choice': 20,
        'token': 'secret',
      },
    }, id)!;
    expect(report['packageSource'], 'persistent');
    expect(report['phasesMs'], {'unpack': 35, 'audio_choice': 20});
    expect(jsonEncode(report), isNot(contains('secret')));
    expect(MiniAppLaunchReport.parse({'appId': 'other'}, id), isNull);
    final windowReport = MiniAppLaunchReport.fromWindow({
      ...report,
      'engine': 'lightweight',
      'viewCreatedMs': 30,
      'cookiesReadyMs': -1,
      'event': 'arbitrary',
      'secret': 'credential',
    }, id)!;
    expect(windowReport['viewCreatedMs'], 30);
    expect(windowReport.containsKey('cookiesReadyMs'), isFalse);
    expect(windowReport['event'], 'mini_app_launch');
    expect(windowReport['independentWindow'], isTrue);
    expect(jsonEncode(windowReport), isNot(contains('credential')));
    expect(MiniAppLaunchReport.fromWindow(windowReport, 'other'), isNull);
    expect(MiniAppEngine.parse('future-engine'), MiniAppEngine.lightweight);
  });

  test('宿主启动诊断区分阶段，只保留错误枚举、状态码及来源校验结果', () {
    final raw = {
      'appId': id,
      'phase': 'session',
      'code': 'ACCESS_DENIED',
      'errorName': 'Error',
      'httpStatus': 403,
      'sameOrigin': true,
      'secureContext': true,
      'entryMatches': true,
      'message': 'token=secret',
      'url': 'https://linux.do/?secret',
      'response': {'csrf': 'secret'},
    };
    final report = MiniAppLaunchReport.hostFailure(raw, id)!;
    expect(report['phase'], 'session');
    expect(report['httpStatus'], 403);
    expect(report['sameOrigin'], true);
    expect(jsonEncode(report), isNot(contains('secret')));
    expect(MiniAppLaunchReport.hostFailure(raw, 'other'), isNull);
    expect(
      MiniAppLaunchReport.hostFailure({...raw, 'phase': 'secret'}, id),
      isNull,
    );
    final sanitized = MiniAppLaunchReport.hostFailure({
      ...raw,
      'errorName': 'secret',
      'httpStatus': 900,
      'sameOrigin': 'secret',
    }, id)!;
    expect(sanitized.containsKey('errorName'), false);
    expect(sanitized.containsKey('httpStatus'), false);
    expect(sanitized.containsKey('sameOrigin'), false);
    final window = MiniAppLaunchReport.fromWindow({
      ...report,
      'message': 'secret',
    }, id)!;
    expect(window['event'], 'mini_app_host_failed');
    expect(window['independentWindow'], true);
    expect(jsonEncode(window), isNot(contains('secret')));
    final sandbox = MiniAppLaunchReport.hostFailure({
      ...raw,
      'phase': 'runtime',
      'code': 'SANDBOX_UNAVAILABLE',
      'frameHost': 'invalid_marker',
      'runtime': 'not_started',
    }, id)!;
    expect(sandbox['frameHost'], 'invalid_marker');
    expect(sandbox['runtime'], 'not_started');
    final unknown = MiniAppLaunchReport.hostFailure({
      ...sandbox,
      'frameHost': 'https://secret',
      'runtime': 'secret-token',
    }, id)!;
    expect(unknown.containsKey('frameHost'), false);
    expect(unknown.containsKey('runtime'), false);
  });

  test('原生启动失败保留可定位的阶段与枚举，跨窗口丢弃任意错误正文', () {
    final raw = {
      'appId': id,
      'engine': 'lightweight',
      'phase': 'document_load',
      'errorName': 'PlatformException',
      'code': 'NSURLErrorDomain -999',
      'message': 'token=secret',
      'url': 'https://linux.do/?secret',
    };
    final report = MiniAppLaunchReport.nativeFailure(raw, id)!;
    expect(report['phase'], 'document_load');
    expect(report.containsKey('code'), false);
    expect(jsonEncode(report), isNot(contains('secret')));
    expect(MiniAppLaunchReport.nativeFailure(raw, 'other'), isNull);
    expect(
      MiniAppLaunchReport.nativeFailure({...raw, 'phase': 'unknown'}, id),
      isNull,
    );
    final window = MiniAppLaunchReport.fromWindow({
      ...report,
      'code': 'TIMED_OUT',
      'message': 'secret',
    }, id)!;
    expect(window['code'], 'TIMED_OUT');
    expect(window['independentWindow'], true);
    expect(jsonEncode(window), isNot(contains('secret')));
  });

  test('状态读取超时单独记警告，独立窗口保留诊断阶段且过滤任意正文', () {
    final report = MiniAppLaunchReport.nativeFailure({
      'appId': id,
      'engine': 'lightweight',
      'phase': 'state_read',
      'errorName': 'TimeoutException',
      'operation': 'evaluate_js',
      'hostReady': true,
      'message': 'secret',
    }, id)!;
    expect(report['event'], 'mini_app_state_read_failed');
    expect(report['level'], 'warning');
    expect(report['hostReady'], true);
    expect(report['operation'], 'evaluate_js');
    expect(jsonEncode(report), isNot(contains('secret')));
    final window = MiniAppLaunchReport.fromWindow(report, id)!;
    expect(window['event'], 'mini_app_state_read_failed');
    expect(window['level'], 'warning');
    expect(window['independentWindow'], true);
    expect(window['hostReady'], true);
    expect(window['operation'], 'evaluate_js');
    final unknown = MiniAppLaunchReport.nativeFailure({
      ...report,
      'operation': 'secret',
      'hostReady': 'secret',
    }, id)!;
    expect(unknown.containsKey('operation'), false);
    expect(unknown.containsKey('hostReady'), false);
    final timeout = MiniAppLaunchReport.nativeFailure({
      ...report,
      'phase': 'timeout',
    }, id)!;
    expect(timeout['event'], 'mini_app_native_boot_failed');
    expect(timeout['level'], 'error');
  });

  test('执行轻量宿主：最新运行器、登录绑定、声音、销毁和异步取消', () async {
    final folder = await Directory.systemTemp.createTemp('mini-app-host-test-');
    try {
      final file = File('${folder.path}/host-test.cjs');
      await file.writeAsString('''
const hostScript = ${jsonEncode(MiniAppLightweightHost.script)};
const configuration = ${jsonEncode(configuration)};
const entry = ${jsonEncode(entry.toString())};
$_fixture
''');
      final result = await Process.run('node', [
        '--experimental-vm-modules',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      await folder.delete(recursive: true);
    }
  });
}

const _fixture = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
const settle = async () => { for(let i=0;i<12;i++) await new Promise(setImmediate); };
async function scenario({badOrigin=false,badAsset=false,wrongUser=false,delay=false,anonymous=false,
  requestFailure=null,importFailure=false,mountFailure=false,insecure=false,runtimeFailure=null,
  delayIdentity=false,nativeCache=null}={}) {
  const calls=[], imports=[], lifecycle={}, listeners={}, links=[];
  let documentLoad;
  const stage={textContent:''},detail={textContent:''},progress={},retry={hidden:true};
  const loading={hidden:false,querySelector:s=>s==='progress'?progress:null};
  const root={contains:frame=>frame.fixture===true,classList:{remove(){},add(){}},querySelector:s=>({
    '.mini-app-loader__loading':loading,'[data-role="stage"]':stage,
    '[data-role="detail"]':detail,'[data-action="retry"]':retry,
  })[s]};
  const page={setAttribute:(name,value)=>page[name]=value};
  const audio={disabled:true,setAttribute:(name,value)=>audio[name]=value,
    addEventListener:(event,fn)=>listeners[event]=fn};
  const release={textContent:''},bootFailure={textContent:''},csrfMeta={content:''};
  const document={head:{append:link=>links.push(link)},createElement:()=>({}),
    addEventListener:(name,fn,options)=>{assert.equal(name,'load');assert.equal(options.capture,true);documentLoad=fn;},
    getElementById:id=>id==='fluxdo-mini-app-boot-failure'?bootFailure:release,
    querySelector:s=>({'.mini-app-loader':root,'.mini-app-page':page,
      '.mini-app-page__audio-trigger':audio,'meta[name="csrf-token"]':csrfMeta})[s]};
  let runtime,options,providerOptions,disposed=0,providerDisposed=0,resolveFetch;
  const moduleSource='export const version = 1;';
  const moduleBytes=new TextEncoder().encode(moduleSource);
  const hash=nativeCache?require('node:crypto').createHash('sha256').update(moduleSource).digest('hex'):'a'.repeat(64);
  const assets={runtimeAssets:{
    loader:(badAsset?'https://evil.example':'')+'/plugins/discourse-mini-app/runtime/loader-'+hash+'.js',
    packageWorker:'/mini-app-api/workers/package-worker-'+hash+'.js',
    preflightWorker:'/mini-app-api/workers/package-preflight-worker-'+hash+'.js',
    frameHostStyle:'/plugins/discourse-mini-app/runtime/frame-host-'+hash+'.css',
    errorStyle:'/plugins/discourse-mini-app/runtime/error-'+hash+'.css',
  },sdkSha256:hash};
  const gate=new Promise(resolve=>resolveFetch=resolve);
  const window={addEventListener:(name,fn)=>lifecycle[name]=fn};
  const nativeCalls=[];
  if(nativeCache) window.flutter_inappwebview={callHandler:async(name,request)=>{
    assert.equal(name,'fluxdoMiniAppRuntime');nativeCalls.push(request);
    if(nativeCache==='unavailable') throw Error('bridge unavailable');
    if(nativeCache==='pending') return gate;
    if(request.action==='read') return nativeCache==='hit'?moduleSource:nativeCache==='corrupt'?'changed':null;
    assert.equal(request.hash,hash);assert.equal(request.source,moduleSource);return true;
  }};
  const location=new URL(badOrigin?'https://evil.example/':entry);
  const context=vm.createContext({
    boot:{configuration:{...configuration,anonymous},entry,prefix:'',expectedUserId:2,failureMessage:'失败'},
    document,window,location,isSecureContext:!insecure,URL,AbortController,AbortSignal,
    setTimeout,clearTimeout,TextEncoder,TextDecoder,Blob,crypto:require('node:crypto').webcrypto,
    history:{replaceState(_state,_title,value){ location.href=value; }},
    fetch:async(path,request)=>{
      calls.push({path,request});
      if(path.includes('/loader-')) {
        let sent=false;
        return {ok:true,body:{getReader:()=>({
          read:async()=>sent?{done:true}:(sent=true,{done:false,value:moduleBytes}),
          cancel:async()=>{},
        })}};
      }
      if(delay) await gate;
      if(delayIdentity && !path.includes('runtime-assets')) await gate;
      if(requestFailure && path===requestFailure.path) {
        if(requestFailure.status) return {ok:false,status:requestFailure.status};
        if(requestFailure.json) return {ok:true,json:async()=>{throw new SyntaxError('secret-response');}};
        throw new TypeError('secret-url');
      }
      const data=path.includes('runtime-assets')?assets:path.includes('csrf')?{csrf:'test-csrf'}:
        path.includes('user-cards')?{users:[{id:3,username:'other'}]}:
        {current_user:{id:wrongUser?9:2,username:'me',avatar_template:'/avatar/{size}.png'}};
      return {ok:true,json:async()=>data};
    },
  });
  const module=new vm.SyntheticModule(['mountLoader','createUserDataProvider'],function(){
    this.setExport('createUserDataProvider',opts=>{
      providerOptions=opts;
      return {getCurrent:opts.getCurrentUser,destroy(){providerDisposed++;}};
    });
    this.setExport('mountLoader',(element,opts)=>{
      if(mountFailure) throw Object.assign(new Error('secret-runtime'), {name:'NotSupportedError'});
      assert.equal(element,root); options=opts;
      runtime={destroy(){disposed++;},async setAudioMuted(value){opts.onAudioStateChange(value);}};
      opts.onAudioStateChange(true);
      opts.onRelease({app_id:configuration.appId,id:4,channel:'production',version:'2.0.0',name:'新的名称',runtime_token:'secret'});
      return runtime;
    });
  },{context});
  await module.link(()=>{});await module.evaluate();
  new vm.Script(hostScript,{importModuleDynamically:async url=>{
    if(importFailure) throw new SyntaxError('secret-loader');
    imports.push(url);return module;
  }}).runInContext(context);
  await settle();
  if(nativeCache && nativeCache!=='pending') {
    // WebCrypto 在线程池完成，等待挂载结果，避免 CPU 忙时只清空微任务仍过早断言。
    for(let attempt=0;attempt<200 && !options && retry.hidden;attempt++) {
      await new Promise(resolve=>setTimeout(resolve,5));
    }
  }
  if(delayIdentity) {
    assert.equal(imports.length,1,'身份请求未返回时运行器已经准备');
    assert.equal(options,undefined,'身份校验前不得挂载应用');
    resolveFetch();
    await settle();
  }
  if(delay){window.fluxdoMiniAppHost.destroy();resolveFetch();await settle();
    assert.equal(imports.length,0);assert.equal(disposed,0);return;}
  if(nativeCache==='pending') {
    assert.equal(nativeCalls.length,1);
    window.fluxdoMiniAppHost.destroy();resolveFetch(moduleSource);await settle();
    assert.equal(imports.length,0,'关闭后不导入迟到的缓存运行器');
    assert.equal(options,undefined);return;
  }
  if(runtimeFailure) {
    let message, tracking;
    const app={contentWindow:{}};
    const child={location:{href:'https://linux.do/mini-app-api/frame-host'},
      addEventListener:(name,fn,options)=>{message=fn;tracking=options.signal;}};
    const doc={body:{},querySelector:s=>s==='body > iframe'?app:
      runtimeFailure==='invalid_marker'?null:{content:'1'}};
    const frame={fixture:true,tagName:'IFRAME',classList:{contains:()=>true},
      src:child.location.href,contentDocument:doc,contentWindow:child};
    if(runtimeFailure==='unexpected_url') child.location.href='https://linux.do/login?secret';
    if(runtimeFailure==='inaccessible') frame.contentDocument=null;
    // 不读取其他 frame；页面正文和凭据不进入诊断。
    documentLoad({target:{...frame,fixture:false,get contentDocument(){throw Error('wrong frame');}}});
    documentLoad({target:frame});
    if(message) {
      message({source:{},origin:'null',data:{type:'runtime-failed',token:'secret'}});
      message({source:app.contentWindow,origin:'https://evil.test',data:{type:'runtime-failed'}});
      if(runtimeFailure==='runtime_failed') {
        message({source:app.contentWindow,origin:'null',data:{type:'runtime-failed',token:'secret'}});
        assert.equal(tracking.aborted,true);
      }
    }
    // 模拟官方运行器内部捕获异常后移除 iframe，再读取错误翻译。
    root.contains=()=>false;
    detail.textContent=options.translations.errors.SANDBOX_UNAVAILABLE;
    const diagnostic=JSON.parse(bootFailure.textContent);
    assert.equal(diagnostic.phase,'runtime');
    assert.equal(diagnostic.code,'SANDBOX_UNAVAILABLE');
    assert.equal(diagnostic.frameHost,['runtime_failed','ready'].includes(runtimeFailure)?'ready':runtimeFailure);
    assert.equal(diagnostic.runtime,runtimeFailure==='runtime_failed'?'failed':'not_started');
    assert.equal(detail.textContent.includes('SANDBOX_UNAVAILABLE'),true);
    assert.equal(detail.textContent.includes('frame_host: '+diagnostic.frameHost),true);
    assert.equal(bootFailure.textContent.includes('secret'),false);
    if(tracking) assert.equal(tracking.aborted,true);
    window.fluxdoMiniAppHost.destroy();
    return;
  }
  if(badOrigin||badAsset||wrongUser||requestFailure||importFailure||mountFailure||insecure){
    if(!requestFailure) assert.equal(imports.length,mountFailure||wrongUser?1:0);
    if(wrongUser||requestFailure) assert.equal(options,undefined);
    assert.equal(retry.hidden,false);assert.equal(stage.textContent,'失败');
    const diagnostic=JSON.parse(bootFailure.textContent);
    assert.equal(diagnostic.appId,configuration.appId);
    assert.equal(diagnostic.phase,requestFailure?.phase || (importFailure?'loader_import':
      mountFailure?'loader_mount':badOrigin||insecure?'environment':badAsset?'runtime_assets':'identity'));
    assert.equal(diagnostic.sameOrigin,!badOrigin);
    assert.equal(diagnostic.secureContext,!insecure);
    assert.equal(detail.textContent.includes(diagnostic.phase),true);
    assert.equal(detail.textContent.includes('secret'),false);
    if(requestFailure?.status) assert.equal(diagnostic.httpStatus,requestFailure.status);
    if(requestFailure?.json||importFailure) assert.equal(diagnostic.errorName,'SyntaxError');
    if(requestFailure && !requestFailure.status && !requestFailure.json) assert.equal(diagnostic.errorName,'TypeError');
    assert.equal(bootFailure.textContent.includes('secret'),false);
    return;
  }
  assert.equal(bootFailure.textContent,'');
  assert.equal(imports.length,1,detail.textContent);
  if(nativeCache==='hit'||nativeCache==='miss') {
    assert.equal(imports[0].startsWith('blob:'),true);
    assert.equal(calls.filter(call=>call.path.includes('/loader-')).length,nativeCache==='hit'?0:1);
    assert.equal(nativeCalls.filter(call=>call.action==='write').length,nativeCache==='hit'?0:1);
  } else assert.equal(imports[0],'https://linux.do/plugins/discourse-mini-app/runtime/loader-'+hash+'.js');
  assert.equal(page['data-fluxdo-mounted'],'');
  assert.equal(options.sdkSha256,hash);
  assert.equal(links.length,2);
  assert.equal(csrfMeta.content,anonymous?'':'test-csrf');
  assert.equal(options.userProvider.getCurrent()?.id,anonymous?undefined:2);
  if(!anonymous){assert.equal((await providerOptions.findById(3)).id,3);}
  assert.equal(JSON.parse(release.textContent).version,'2.0.0');
  assert.equal(release.textContent.includes('secret'),false);
  assert.equal(audio['aria-pressed'],'false');await listeners.click();
  assert.equal(audio['aria-pressed'],'true');
  await window.fluxdoMiniAppHost.setSuspended(true);
  assert.equal(audio['aria-pressed'],'false');
  await window.fluxdoMiniAppHost.setSuspended(true);
  await window.fluxdoMiniAppHost.setSuspended(false);
  assert.equal(audio['aria-pressed'],'true');
  await Promise.all([window.fluxdoMiniAppHost.setSuspended(true),
    window.fluxdoMiniAppHost.setSuspended(false)]);
  assert.equal(audio['aria-pressed'],'true');
  assert.equal(calls.some(c=>c.path.includes('/apps/')),false);
  assert.equal(calls.filter(c=>!c.path.includes('/loader-')).every(c=>c.request.cache==='no-store'),true);
  lifecycle.pagehide();window.fluxdoMiniAppHost.destroy();
  assert.equal(disposed,1);assert.equal(providerDisposed,1);
  assert.equal(calls.every(c=>c.request.signal.aborted),true);
}
(async()=>{
  await scenario();await scenario({anonymous:true});await scenario({badOrigin:true});
  await scenario({badAsset:true});await scenario({wrongUser:true});await scenario({delay:true});
  await scenario({delayIdentity:true});
  for(const nativeCache of ['hit','miss','corrupt','unavailable','pending']) await scenario({nativeCache});
  await scenario({insecure:true});await scenario({importFailure:true});await scenario({mountFailure:true});
  await scenario({requestFailure:{path:'/session/current.json',phase:'session',status:403}});
  await scenario({requestFailure:{path:'/session/csrf',phase:'csrf',json:true}});
  await scenario({requestFailure:{path:'/mini-app-api/runtime-assets.json',phase:'runtime_assets'}});
  for(const runtimeFailure of ['invalid_marker','unexpected_url','inaccessible','ready','runtime_failed']) {
    await scenario({runtimeFailure});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
''';
