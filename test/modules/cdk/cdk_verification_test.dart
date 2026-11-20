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
        var window = {flutter_inappwebview: {callHandler: (name, type, value) => {
          sendMessage('${MetaverseScriptEngine.channel}', JSON.stringify({name, type, value}));
        }}, hcaptcha: {render: (panel, options) => {captured = options;}}};
        var document = {
          createElement: () => ({style: {}}),
          body: {appendChild: node => nodes.push(node)},
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
        if (captured.sitekey !== 'fixture-key' || captured.size !== 'normal') throw new Error('bad config');
        if (nodes.length !== 1) throw new Error('duplicate overlay');
      ''');
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
        if (captured.size !== 'compact' || captured.theme !== 'dark') throw new Error('narrow verification layout');
      ''');
    } finally {
      engine.dispose();
      await engine.terminated;
    }
  });
}
