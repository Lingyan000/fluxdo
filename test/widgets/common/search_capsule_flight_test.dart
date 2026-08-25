import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/common/search_capsule.dart';

/// 搜索胶囊 Hero shuttle:插值飞行体在中途帧必须同时携带两端要素
/// (图标渐隐+双 hint 交叉),起飞/落地帧与两端真实视觉一致,不再是
/// 与两端都不匹配的静态胶囊(旧版闪烁来源)。
void main() {
  Widget buildApp({required Widget homeChild}) {
    return TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                SizedBox(
                  width: 300,
                  height: 40,
                  child: Hero(
                    tag: kSearchCapsuleHeroTag,
                    flightShuttleBuilder: searchCapsuleFlightShuttle,
                    child: homeChild,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(
                          title: Hero(
                            tag: kSearchCapsuleHeroTag,
                            flightShuttleBuilder: searchCapsuleFlightShuttle,
                            child: Container(
                              height: 40,
                              color: Colors.grey,
                              child: const Text('search field'),
                            ),
                          ),
                        ),
                        body: const Text('search page'),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pop 飞行中途:插值 shuttle 带图标,不抛异常', (tester) async {
    await tester.pumpWidget(buildApp(homeChild: const SearchCapsule()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 飞行中途:shuttle 在 overlay 上,含搜索图标(靠近首页端应可见)
    expect(find.byIcon(Symbols.search_rounded), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('首页端收缩态(morph 参数)不影响飞行稳定性', (tester) async {
    await tester.pumpWidget(
      buildApp(
        homeChild: const SearchCapsule(
          hintOpacity: 0,
          iconSize: 24,
          iconLeftPadding: 8,
          backgroundOpacity: 0,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });
}
