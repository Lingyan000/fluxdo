import 'package:flutter_test/flutter_test.dart';

import '../../tool/_cli_ui.dart';

void main() {
  group('RelativeRenderBlock', () {
    test('首次渲染不输出光标回退序列，且末尾不附带多余换行', () {
      final block = RelativeRenderBlock();
      final out = StringBuffer();

      block.render(['line1', 'line2', 'line3'], sink: out);

      expect(out.toString(), 'line1\nline2\nline3');
      expect(block.renderedLines, 3);
    });

    test('重绘使用相对上移并清屏，避免终端滚屏时菜单重复叠画', () {
      final block = RelativeRenderBlock();
      final out = StringBuffer();

      block.render(['title', 'help', '> opt1', '  opt2'], sink: out);
      out.clear();

      block.render(['title', 'help', '  opt1', '> opt2'], sink: out);

      expect(
        out.toString(),
        '\r\x1b[3A\x1b[Jtitle\nhelp\n  opt1\n> opt2',
      );
      expect(block.renderedLines, 4);
    });

    test('单行块重绘与清除只回行首并清屏，不误上移一行', () {
      final block = RelativeRenderBlock();
      final out = StringBuffer();

      block.render(['confirm line'], sink: out);
      out.clear();

      block.render(['confirm line 2'], sink: out);
      expect(out.toString(), '\r\x1b[Jconfirm line 2');

      out.clear();
      block.clear(sink: out);
      expect(out.toString(), '\r\x1b[J');
      expect(block.renderedLines, 0);
    });
  });

  group('文本显示宽度与 ANSI 截断', () {
    test('正确区分 ASCII、CJK 与 ANSI 转义码宽度', () {
      expect(displayWidth('abc'), 3);
      expect(displayWidth('中文'), 4);
      expect(displayWidth('\x1b[1;96m发版\x1b[0m v1'), 7);
    });

    test('超宽带色文本安全截断并补齐重置码，确保物理上只占 1 行', () {
      final truncated = truncateAnsi('\x1b[96m选择稳定版类型 patch 修复发布\x1b[0m', 12);
      expect(displayWidth(truncated), lessThanOrEqualTo(12));
      expect(truncated.endsWith('…\x1b[0m'), isTrue);
    });

    test('padRightDisplayWidth 按终端显示宽度对齐中文标签', () {
      expect(displayWidth(padRightDisplayWidth('版本', 8)), 8);
      expect(displayWidth(padRightDisplayWidth('Tag', 8)), 8);
    });
  });
}
