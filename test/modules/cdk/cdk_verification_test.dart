import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/cdk/ui/cdk_verification_sheet.dart';
import 'package:fluxdo/modules/metaverse/plugin/runtime/flutter_js_script_engine.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

void main() {
  test('验证桥读取官网 sitekey，由用户验证，绝不触发领取接口', () async {
    final engine = await IsolateScriptEngine.spawn();
    final messages = <Map>[];
    engine.onMessage = (message) {
      messages.add(message as Map);
    };
    try {
      await engine.evaluate('''
        var timer;
        var captured;
        var nodes = [];
        var executions = [];
        var window = {flutter_inappwebview: {callHandler: (name, type, value) => {
          sendMessage('${MetaverseScriptEngine.channel}', JSON.stringify({name, type, value}));
        }}, hcaptcha: {
          render: (panel, options) => {captured = options; return 42;},
          execute: id => executions.push(id)
        }};
        var site = {style: {}, inert: false};
        var document = {
          createElement: () => ({style: {}}),
          documentElement: {style: {}},
          body: {style: {}, children: [site], appendChild: node => nodes.push(node)},
          querySelectorAll: () => [{src: 'fixture-frame'}]
        };
        var URL = function(value) {this.protocol='https:'; this.hostname='newassets.hcaptcha.com'; this.hash='#sitekey=fixture-key'; this.search='';};
        var URLSearchParams = function(value) {this.get = key => value === 'sitekey=fixture-key' && key === 'sitekey' ? 'fixture-key' : null;};
        var setInterval = fn => {timer = fn; return 1};
        var clearInterval = () => {};
        var fetch = () => {throw new Error('unexpected network')};
      ''');
      await engine.evaluate(
        cdkVerificationScript(background: '#ffffff', dark: false),
      );
      await engine.evaluate('timer(); captured.callback("user-verified");');
      expect(messages.map((m) => m['type']), ['ready', 'token']);
      expect(messages.last['value'], 'user-verified');
      await engine.evaluate('''
        if (captured.sitekey !== 'fixture-key' || captured.size !== 'invisible') throw new Error('bad config');
        if (executions.length !== 1 || executions[0] !== 42) throw new Error('wrong widget executed');
        if (!site.inert || site.style.visibility !== 'hidden') throw new Error('business page reachable');
        if (nodes.length !== 1) throw new Error('duplicate overlay');
        captured.callback('duplicate');
        captured['close-callback']();
      ''');
      expect(messages, hasLength(2));
      await engine.evaluate(
        cdkVerificationScript(background: '#ffffff', dark: false),
      );
      await engine.evaluate(
        'if (nodes.length !== 1) throw new Error("duplicate overlay")',
      );
      await engine.evaluate('''
        window.__fluxdoCdkCaptcha = false;
        window.innerWidth = 288;
      ''');
      await engine.evaluate(
        cdkVerificationScript(background: '#111111', dark: true),
      );
      await engine.evaluate('''
        timer();
        if (captured.size !== 'invisible' || captured.theme !== 'dark') throw new Error('narrow verification layout');
        captured['open-callback']();
        captured['chalexpired-callback']();
        captured.callback('stale-token');
      ''');
      expect(messages.map((m) => m['type']), [
        'ready',
        'token',
        'ready',
        'challenge',
        'error',
      ]);
      expect(messages.last['value'], 'expired');
    } finally {
      engine.dispose();
      await engine.terminated;
    }
  });

  test('验证只接受当前项目的 HTTPS 原站页面', () {
    expect(
      isCdkVerificationUrl(
        Uri.parse('https://cdk.linux.do/receive/project-1'),
        'project-1',
      ),
      isTrue,
    );
    for (final url in [
      'http://cdk.linux.do/receive/project-1',
      'https://cdk.linux.do.evil.test/receive/project-1',
      'https://cdk.linux.do/receive/project-2',
      'https://cdk.linux.do/receive/project-1?redirect=1',
      'https://user@cdk.linux.do/receive/project-1',
      'about:blank',
      'https:project-1',
    ]) {
      expect(
        isCdkVerificationUrl(Uri.parse(url), 'project-1'),
        isFalse,
        reason: url,
      );
    }
  });
}
