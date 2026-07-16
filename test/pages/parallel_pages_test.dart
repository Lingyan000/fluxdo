import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/search_page.dart';
import 'package:fluxdo/pages/settings_page.dart';

Widget _layoutProbe(Size size) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Builder(
        builder: (context) => Column(
          children: [
            Text('search:${SearchPage.canShowParallelFor(context)}'),
            Text('settings:${SettingsPage.canShowParallelFor(context)}'),
          ],
        ),
      ),
    ),
  );
}

void main() {
  test('搜索框标准化无协议的 L 站链接', () {
    expect(
      normalizeDirectSearchLink('linux.do/t/topic/123/4'),
      'https://linux.do/t/topic/123/4',
    );
    expect(
      normalizeDirectSearchLink('www.linux.do/u/alice'),
      'https://www.linux.do/u/alice',
    );
    expect(normalizeDirectSearchLink('/t/123'), '/t/123');
    expect(normalizeDirectSearchLink('普通关键词'), '普通关键词');
  });

  testWidgets('宽屏搜索与设置启用平行视界', (tester) async {
    await tester.pumpWidget(_layoutProbe(const Size(1280, 800)));

    expect(find.text('search:true'), findsOneWidget);
    expect(find.text('settings:true'), findsOneWidget);
  });

  testWidgets('窄屏搜索与设置保持单页导航', (tester) async {
    await tester.pumpWidget(_layoutProbe(const Size(700, 800)));

    expect(find.text('search:false'), findsOneWidget);
    expect(find.text('settings:false'), findsOneWidget);
  });
}
