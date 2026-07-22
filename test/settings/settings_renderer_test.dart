import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/settings/settings_model.dart';
import 'package:fluxdo/settings/settings_renderer.dart';

void main() {
  testWidgets('指定的功能说明可自然换行且不显示省略号', (tester) async {
    const subtitle = '这是一段在窄屏中需要完整换行显示、不能被省略号截断的功能介绍';
    final model = ActionModel(
      id: 'wrapping-action',
      title: '长说明功能',
      subtitle: subtitle,
      icon: Symbols.info_rounded,
      wrapSubtitle: true,
      onTap: (_, _) {},
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 280, child: SettingsRenderer(model: model)),
          ),
        ),
      ),
    );

    final subtitleText = tester.widget<Text>(find.text(subtitle));
    expect(subtitleText.maxLines, isNull);
    expect(subtitleText.overflow, TextOverflow.visible);
    expect(tester.takeException(), isNull);
  });
}
