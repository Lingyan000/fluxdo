import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/settings/settings_model.dart';
import 'package:fluxdo/settings/settings_renderer.dart';

void main() {
  // 断言渲染结果而不是 maxLines/overflow 这两个参数本身:换成任何等价实现
  // (softWrap、固定行数上限)只要用户看到的还是"完整多行、无省略号",测试就该绿。
  testWidgets('长副标题:wrapSubtitle 关闭时截断为单行，开启后完整换行', (tester) async {
    const subtitle = '这是一段在窄屏中需要完整换行显示、不能被省略号截断的功能介绍文字';

    Future<({double height, bool truncated})> pumpAndMeasure({
      required bool wrap,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 280,
                child: SettingsRenderer(
                  model: ActionModel(
                    id: 'wrapping-action',
                    title: '长说明功能',
                    subtitle: subtitle,
                    icon: Symbols.info_rounded,
                    wrapSubtitle: wrap,
                    onTap: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(subtitle),
      );
      return (
        height: paragraph.size.height,
        truncated: paragraph.didExceedMaxLines,
      );
    }

    final clamped = await pumpAndMeasure(wrap: false);
    final wrapped = await pumpAndMeasure(wrap: true);

    expect(clamped.truncated, isTrue, reason: '默认单行:超长副标题应被省略号截断');
    expect(wrapped.truncated, isFalse, reason: '开启后不应再截断');
    expect(
      wrapped.height,
      greaterThan(clamped.height),
      reason: '开启后应按内容摊开为多行，高度必然大于单行',
    );
    expect(tester.takeException(), isNull);
  });
}
