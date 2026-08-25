import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 机制实锤:placeholder 的 middle 对齐到底用哪份字体度量?
  // 候选:段落默认样式(14px) vs 占位前 push 的 span 样式。
  // 两个段落只差 push 的字号,若占位盒位置不同 => span 样式支配。
  test('placeholder middle 以 span 样式度量计算', () {
    ui.Paragraph build(double spanFontSize) {
      final b = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 14))
        ..pushStyle(ui.TextStyle(fontSize: spanFontSize))
        ..addPlaceholder(12, 12, ui.PlaceholderAlignment.middle)
        ..addText('123');
      return b.build()..layout(const ui.ParagraphConstraints(width: 300));
    }

    final p11 = build(11);
    final p22 = build(22);
    final r11 = p11.getBoxesForPlaceholders().first.toRect();
    final r22 = p22.getBoxesForPlaceholders().first.toRect();
    // 相对基线的盒中心(负值 = 基线上方)
    final c11 = r11.center.dy - p11.alphabeticBaseline;
    final c22 = r22.center.dy - p22.alphabeticBaseline;
    // ignore: avoid_print
    print('span11: box=$r11 baseline=${p11.alphabeticBaseline} center=$c11');
    // ignore: avoid_print
    print('span22: box=$r22 baseline=${p22.alphabeticBaseline} center=$c22');
    // FlutterTest 测试字体 ascent=0.75em, descent=0.25em
    // => middle = (0.75-0.25)/2 * fs = 0.25*fs(基线上方)
    // span 支配: c11=-2.75, c22=-5.5;段落默认支配: 两者同 =-3.5
    expect((c22 - c11).abs(), greaterThan(1.0),
        reason: '两个字号的占位盒中心应不同 => middle 用 span 样式度量');
  });
}
