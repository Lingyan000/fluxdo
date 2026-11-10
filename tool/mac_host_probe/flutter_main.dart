import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'mini_app.dart';
import 'mini_app_host_adapter.dart';
import 'mini_app_lightweight_host.dart';
import 'mini_app_url.dart';

const id = '01a1b02d-04ed-7342-baa5-769b244b7b9a';
final entry = Uri.parse('https://community.miniapp-probe.test:8765/apps/$id?embed_mode=true&room=42#invite');
late final String html, compat;
void report(String event, Object? value) => print(jsonEncode({'event': event, 'value': value}));
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Timer(const Duration(seconds: 45), () => exit(1));
  final config = jsonDecode(await rootBundle.loadString('assets/configuration.json')) as Map<String, dynamic>;
  html = MiniAppLightweightHost.build(details: MiniAppDetails(const MiniApp(id:id,name:'Fixture'),entry.toString(),configuration:config),entry:entry,site:entry.origin,background:'#ffffff',foreground:'#111111',primary:'#123456',expectedUserId:2,failureMessage:'Host failed',preparingMessage:'Preparing');
  compat = await rootBundle.loadString('assets/compat-polyfill.js');
  runApp(const MaterialApp(home: Probe()));
}
class Probe extends StatelessWidget {
  const Probe({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(body: InAppWebView(
    initialSettings: InAppWebViewSettings(javaScriptEnabled:true, sharedCookiesEnabled:true,domStorageEnabled:true,cacheEnabled:true,isInspectable:true,
      useShouldOverrideUrlLoading:true,mediaPlaybackRequiresUserGesture:false,allowsInlineMediaPlayback:true,thirdPartyCookiesEnabled:true,
      javaScriptBridgeForMainFrameOnly:true,javaScriptHandlersForMainFrameOnly:true),
    initialUserScripts: UnmodifiableListView([
      UserScript(source:'window.__fluxdoErudaInited=true;',injectionTime:UserScriptInjectionTime.AT_DOCUMENT_START,forMainFrameOnly:true),
      UserScript(source:compat,injectionTime:UserScriptInjectionTime.AT_DOCUMENT_START,forMainFrameOnly:true),
      UserScript(source:MiniAppHostAdapter.frameViewportScript(Uri.parse(entry.origin)),injectionTime:UserScriptInjectionTime.AT_DOCUMENT_START,forMainFrameOnly:false),
      UserScript(source:MiniAppHostAdapter.navigationScript(entry),injectionTime:UserScriptInjectionTime.AT_DOCUMENT_START,forMainFrameOnly:true),
    ]),
    onWebViewCreated:(controller) async {
      try {
        await CookieManager.instance().setCookie(url:WebUri(entry.origin),name:'probe_session',value:'synthetic',isSecure:true,sameSite:HTTPCookieSameSitePolicy.LAX);
        await controller.loadData(data:html,baseUrl:WebUri(entry.toString()),historyUrl:WebUri(entry.toString()));
        report('flutter-load-started',true);
        Timer.periodic(const Duration(seconds:2),(timer) async {
          try {
            report('flutter-url',(await controller.getUrl()).toString());
            final state=await controller.evaluateJavascript(source:MiniAppHostAdapter.snapshot);
            report('flutter-snapshot',state);
            if(state is Map && state['engineMounted']==true && state['detail']=='EXPECTED_FIXTURE_DENIAL') exit(0);
          }
          catch(e){report('flutter-snapshot-error',e.toString());}
        });
      } catch(e){report('flutter-load-error',e.toString());}
    },
    onLoadStart:(c,u)=>report('flutter-start',u.toString()),
    onLoadStop:(c,u) async {report('flutter-stop',u.toString());await c.injectCSSCode(source:MiniAppHostAdapter.css);},
    onReceivedError:(c,r,e)=>report('flutter-error',{'type':e.type.toString(),'description':e.description,'main':r.isForMainFrame}),
    onConsoleMessage:(c,m)=>report('flutter-console',m.message),
    onReceivedServerTrustAuthRequest:(c,challenge) async => challenge.protectionSpace.host=='community.miniapp-probe.test'?ServerTrustAuthResponse(action:ServerTrustAuthResponseAction.PROCEED):null,
    shouldOverrideUrlLoading:(c,a) async {
      final uri=a.request.url;
      var allow=uri==null;
      if(uri!=null && {'https','http','about','blob','data'}.contains(uri.scheme)) {
        final appUri=MiniAppUrl.parse(uri.toString(),entry.origin);
        allow=a.isForMainFrame!=true || (appUri!=null && MiniAppUrl.appId(appUri)==id) || uri.toString()=='about:blank';
      }
      report('flutter-navigation',{'url':uri.toString(),'main':a.isForMainFrame,'allow':allow});
      return allow?NavigationActionPolicy.ALLOW:NavigationActionPolicy.CANCEL;
    },
  ));
}
