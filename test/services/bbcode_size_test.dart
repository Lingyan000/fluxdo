/// `[size=N]` 的客户端本地 cook 转换。
///
/// 字号 BBCode 由服务端插件提供,不在本地 cook bundle 里 —— cook 会把
/// `[size=N]` 原样当文字吐回来。不在 cook 之后补上,编辑器的往返门禁
/// (cook(raw) vs cook(docToRaw(doc)))就会判有损,整帖降级源码模式。
///
/// 映射基准取服务端真实样本:`[size=0]`→`0%`、`[size=150]`→`150%`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';

void main() {
  group('applyBbcodeSize', () {
    test('真实样本:size=0 → font-size:0%', () {
      expect(
        DiscourseCookService.applyBbcodeSize('<p>[size=0]收到请回复123[/size]</p>'),
        '<p><span style="font-size:0%">收到请回复123</span></p>',
      );
    });

    test('真实样本:size=150 → font-size:150%', () {
      expect(
        DiscourseCookService.applyBbcodeSize('<p>[size=150]hifumi！[/size]</p>'),
        '<p><span style="font-size:150%">hifumi！</span></p>',
      );
    });

    test('同段落多处各自转换', () {
      final out = DiscourseCookService.applyBbcodeSize(
          '<p>[size=0]甲[/size]中间[size=200]乙[/size]</p>');
      expect(out, contains('font-size:0%'));
      expect(out, contains('font-size:200%'));
      expect(out, contains('中间'));
    });

    test('非数字值原样留着(当普通文本)', () {
      const raw = '<p>[size=大]文字[/size]</p>';
      expect(DiscourseCookService.applyBbcodeSize(raw), raw);
    });

    test('没有闭标签不吞内容', () {
      const raw = '<p>[size=100]没闭合</p>';
      expect(DiscourseCookService.applyBbcodeSize(raw), raw);
    });

    test('不影响无 size 的内容', () {
      const raw = '<p>普通文本 [color=red]红[/color]</p>';
      expect(DiscourseCookService.applyBbcodeSize(raw), raw);
    });
  });
}
