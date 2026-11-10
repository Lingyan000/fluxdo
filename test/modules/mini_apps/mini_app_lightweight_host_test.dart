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
  requestFailure=null,importFailure=false,mountFailure=false,insecure=false}={}) {
  const calls=[], imports=[], lifecycle={}, listeners={}, links=[];
  const stage={textContent:''},detail={textContent:''},progress={},retry={hidden:true};
  const loading={hidden:false,querySelector:s=>s==='progress'?progress:null};
  const root={classList:{remove(){},add(){}},querySelector:s=>({
    '.mini-app-loader__loading':loading,'[data-role="stage"]':stage,
    '[data-role="detail"]':detail,'[data-action="retry"]':retry,
  })[s]};
  const page={setAttribute:(name,value)=>page[name]=value};
  const audio={disabled:true,setAttribute:(name,value)=>audio[name]=value,
    addEventListener:(event,fn)=>listeners[event]=fn};
  const release={textContent:''},bootFailure={textContent:''},csrfMeta={content:''};
  const document={head:{append:link=>links.push(link)},createElement:()=>({}),
    getElementById:id=>id==='fluxdo-mini-app-boot-failure'?bootFailure:release,
    querySelector:s=>({'.mini-app-loader':root,'.mini-app-page':page,
      '.mini-app-page__audio-trigger':audio,'meta[name="csrf-token"]':csrfMeta})[s]};
  let runtime,options,providerOptions,disposed=0,providerDisposed=0,resolveFetch;
  const hash='a'.repeat(64);
  const assets={runtimeAssets:{
    loader:(badAsset?'https://evil.example':'')+'/plugins/discourse-mini-app/runtime/loader-'+hash+'.js',
    packageWorker:'/mini-app-api/workers/package-worker-'+hash+'.js',
    preflightWorker:'/mini-app-api/workers/package-preflight-worker-'+hash+'.js',
    frameHostStyle:'/plugins/discourse-mini-app/runtime/frame-host-'+hash+'.css',
    errorStyle:'/plugins/discourse-mini-app/runtime/error-'+hash+'.css',
  },sdkSha256:hash};
  const gate=new Promise(resolve=>resolveFetch=resolve);
  const window={addEventListener:(name,fn)=>lifecycle[name]=fn};
  const location=new URL(badOrigin?'https://evil.example/':entry);
  const context=vm.createContext({
    boot:{configuration:{...configuration,anonymous},entry,prefix:'',expectedUserId:2,failureMessage:'失败'},
    document,window,location,isSecureContext:!insecure,URL,AbortController,AbortSignal,
    history:{replaceState(_state,_title,value){ location.href=value; }},
    fetch:async(path,request)=>{
      calls.push({path,request});
      if(delay) await gate;
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
  if(delay){window.fluxdoMiniAppHost.destroy();resolveFetch();await settle();
    assert.equal(imports.length,0);assert.equal(disposed,0);return;}
  if(badOrigin||badAsset||wrongUser||requestFailure||importFailure||mountFailure||insecure){
    assert.equal(imports.length,mountFailure?1:0);
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
  assert.equal(imports[0],'https://linux.do/plugins/discourse-mini-app/runtime/loader-'+hash+'.js');
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
  assert.equal(calls.every(c=>c.request.cache==='no-store'),true);
  lifecycle.pagehide();window.fluxdoMiniAppHost.destroy();
  assert.equal(disposed,1);assert.equal(providerDisposed,1);
  assert.equal(calls.every(c=>c.request.signal.aborted),true);
}
(async()=>{
  await scenario();await scenario({anonymous:true});await scenario({badOrigin:true});
  await scenario({badAsset:true});await scenario({wrongUser:true});await scenario({delay:true});
  await scenario({insecure:true});await scenario({importFailure:true});await scenario({mountFailure:true});
  await scenario({requestFailure:{path:'/session/current.json',phase:'session',status:403}});
  await scenario({requestFailure:{path:'/session/csrf',phase:'csrf',json:true}});
  await scenario({requestFailure:{path:'/mini-app-api/runtime-assets.json',phase:'runtime_assets'}});
})().catch(error=>{console.error(error);process.exitCode=1;});
''';
