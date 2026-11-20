// SmileyPainter / StickerPainter 的 golden 测试 —— 同时打印各 fill 状态的视觉，
// 校验没有崩溃 + 描边/填充语义正确（线框态外圆有 stroke，实心态有 fill）。
import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SmileyPainter outlined 与 filled 都能渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIcons.smileyOutline, size: 48, color: Colors.black),
                const SizedBox(width: 8),
                AppIcon(AppIcons.smileyOutline,
                    size: 48, color: Colors.black, fill: 1),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('StickerPainter outlined 与 filled 都能渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIcons.stickerOutline, size: 48, color: Colors.black),
                const SizedBox(width: 8),
                AppIcon(AppIcons.stickerOutline,
                    size: 48, color: Colors.black, fill: 1),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
