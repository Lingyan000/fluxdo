import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/network_settings_page/widgets/ech_settings_card.dart';
import 'package:fluxdo/services/network/doh/ech_dns_policy.dart';

Widget host(Widget child, {bool dark = false, double scale = 1}) =>
    TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('关闭公共入口后隐藏域名管理，保留 ECH 配置服务器和自定义规则', (tester) async {
    var policy = const EchDnsPolicy(customDomains: ['example.com']);
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            return EchSettingsCard(
              policy: policy,
              serverSelector: const ListTile(title: Text('ECH 配置服务器')),
              onChanged: (value) => setState(() => policy = value),
            );
          },
        ),
      ),
    );
    expect(find.text('适用域名'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('适用域名'), findsNothing);
    expect(find.text('ECH 配置服务器'), findsOneWidget);
    expect(policy.customDomains, ['example.com']);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('适用域名'), findsOneWidget);
  });

  testWidgets('完整弹层流程支持添加、编辑和保存，取消不应用草稿', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var policy = const EchDnsPolicy();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: host(
          StatefulBuilder(
            builder: (context, setState) => EchSettingsCard(
              policy: policy,
              serverSelector: const ListTile(title: Text('ECH 配置服务器')),
              onChanged: (value) => setState(() => policy = value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('适用域名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'example.com');
    await tester.tap(find.widgetWithText(FilledButton, '保存').last);
    await tester.pumpAndSettle();
    expect(policy.customDomains, isEmpty);
    await tester.ensureVisible(find.text('example.com'));
    await tester.tap(find.text('example.com'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'images.example.net');
    await tester.tap(find.widgetWithText(FilledButton, '保存').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(policy.customDomains, ['images.example.net']);
    expect(find.byType(EchDomainsEditor), findsNothing);

    await tester.tap(find.text('适用域名'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('删除'),
      100,
      scrollable: find.descendant(
        of: find.byType(EchDomainsEditor),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(policy.customDomains, ['images.example.net']);
  });

  testWidgets('删除暂存到保存时才应用，内置域名不可删除', (tester) async {
    List<String>? saved;
    await tester.pumpWidget(
      host(
        EchDomainsEditor(
          initialDomains: const ['example.com'],
          onSave: (domains) => saved = domains,
        ),
      ),
    );
    expect(find.text('linux.do'), findsOneWidget);
    expect(find.text('ldstatic.com'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('example.com'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    expect(saved, isEmpty);
  });

  testWidgets('无效和被覆盖域名显示字段错误，可修改后正常保存', (tester) async {
    String? saved;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              saved = await showDialog<String>(
                context: context,
                builder: (_) => const EchDomainDialog(
                  existingDomains: ['linux.do', 'example.com'],
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'https://example.com');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入有效域名'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'cdn.linux.do');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('该域名已被现有规则覆盖'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), ' CDN.Example.NET. ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(saved, 'cdn.example.net');
  });

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(1024, 768),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('域名编辑布局 $size dark=$dark 大字体无溢出', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          host(
            EchDomainsEditor(
              initialDomains: const ['a-very-long-custom-domain.example.com'],
              onSave: (_) {},
            ),
            dark: dark,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final save = find.widgetWithText(FilledButton, '保存');
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(size.height));
        await tester.pumpWidget(
          host(
            ListView(
              children: [
                EchSettingsCard(
                  policy: const EchDnsPolicy(customDomains: ['example.com']),
                  serverSelector: const ListTile(title: Text('ECH 配置服务器')),
                  onChanged: (_) {},
                ),
              ],
            ),
            dark: dark,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
