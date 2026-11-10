import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'mini_app.dart';
import 'mini_app_host_adapter.dart';
import 'mini_app_lightweight_host.dart';

const id = '01a1b02d-04ed-7342-baa5-769b244b7b9a';
final entry = Uri.parse('https://localhost:8765/apps/$id?embed_mode=true&room=42#invite');
late final String html, compat;
void report(String event, Object? value) => print(jsonEncode({'event': event, 'value': value}));
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = jsonDecode(File('build/mac-probe/configuration.json').readAsStringSync()) as Map<String, dynamic>;
  html = MiniAppLightweightHost.build(details: MiniAppDetails(const MiniApp(id:id,name:'Fixture'),entry.toString(),configuration:config),entry:entry,site:entry.origin,background:'#ffffff',foreground:'#111111',primary:'#123456',expectedUserId:2,failureMessage:'Host failed',preparingMessage:'Preparing');
  compat = File('assets/polyfill/compat-polyfill.js').readAsStringSync();
  Timer(const Duration(seconds: 25), () => exit(0));
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
      UserScript(source:MiniAppHostAdapter.frameViewportScript(entry),injectionTime:UserScriptInjectionTime.AT_DOCUMENT_START,forMainFrameOnly:false),
      UserScript(source:MiniAppHostAdapter.navigationScript(entry),injectionTime:UserScriptInjectionTime.AT_DOCUMENT_START,forMainFrameOnly:true),
    ]),
    onWebViewCreated:(controller) async {
      try {
        await CookieManager.instance().setCookie(url:WebUri(entry.origin),name:'probe_session',value:'synthetic',isSecure:true,sameSite:HTTPCookieSameSitePolicy.LAX);
        await controller.loadData(data:html,baseUrl:WebUri(entry.toString()),historyUrl:WebUri(entry.toString()));
        report('flutter-load-started',true);
        Timer.periodic(const Duration(seconds:2),(timer) async {
          try {report('flutter-url',(await controller.getUrl()).toString());report('flutter-snapshot',await controller.evaluateJavascript(source:MiniAppHostAdapter.snapshot));}
          catch(e){report('flutter-snapshot-error',e.toString());}
        });
      } catch(e){report('flutter-load-error',e.toString());}
    },
    onLoadStart:(c,u)=>report('flutter-start',u.toString()),
    onLoadStop:(c,u) async {report('flutter-stop',u.toString());await c.injectCSSCode(source:MiniAppHostAdapter.css);},
    onReceivedError:(c,r,e)=>report('flutter-error',{'type':e.type.toString(),'description':e.description,'main':r.isForMainFrame}),
    onConsoleMessage:(c,m)=>report('flutter-console',m.message),
    onReceivedServerTrustAuthRequest:(c,challenge) async => challenge.protectionSpace.host=='localhost'?ServerTrustAuthResponse(action:ServerTrustAuthResponseAction.PROCEED):null,
    shouldOverrideUrlLoading:(c,a) async {report('flutter-navigation',{'url':a.request.url.toString(),'main':a.isForMainFrame});return NavigationActionPolicy.ALLOW;},
  ));
}
