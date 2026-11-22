import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final provider = AiProvider(
    id: 'provider',
    name: '测试供应商',
    type: AiProviderType.openai,
    baseUrl: 'https://example.com',
    models: const [AiModel(id: 'text-model')],
  );

  Future<SharedPreferences> pumpPage(
    WidgetTester tester,
    Widget page, {
    required GlobalKey<NavigatorState> pane,
    required bool blur,
  }) async {
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
      'pref_dialog_blur': blur,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          aiSharedPreferencesProvider.overrideWithValue(prefs),
          aiDialogPresenterProvider.overrideWithValue(showAppDialog),
          aiBottomSheetPresenterProvider.overrideWithValue(showAppBottomSheet),
        ],
        child: MaterialApp(
          home: Navigator(
            key: pane,
            onGenerateRoute: (_) => InteractionPageRoute(builder: (_) => page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  testWidgets('模型选择使用当前窗格的公共弹层，保存与清除都返回配置页', (tester) async {
    final pane = GlobalKey<NavigatorState>();
    final prefs = await pumpPage(
      tester,
      const AiProvidersPage(),
      pane: pane,
      blur: true,
    );
    await tester.tap(find.text(AiL10n.current.modelConfig));
    await tester.pumpAndSettle();
    final config = tester.element(find.byType(AiModelConfigPage));
    expect(ModalRoute.of(config), isA<InteractionPageRoute>());

    await tester.tap(find.text(AiL10n.current.notSet).first);
    await tester.pumpAndSettle();
    final shell = find.byType(AppSheetScaffold);
    final route = ModalRoute.of(tester.element(shell));
    expect(route?.navigator, same(pane.currentState));
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.tap(find.text('text-model'));
    await tester.pumpAndSettle();
    expect(prefs.getString('ai_default_text_model'), 'provider:text-model');
    expect(find.byType(AiModelConfigPage), findsOneWidget);

    await tester.tap(find.text('text-model'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: shell, matching: find.text(AiL10n.current.notSet)),
    );
    await tester.pumpAndSettle();
    expect(prefs.getString('ai_default_text_model'), isNull);
    expect(find.byType(AiModelConfigPage), findsOneWidget);
  });

  testWidgets('根层删除确认遵守模糊偏好，取消后保留供应商和窗格', (tester) async {
    final pane = GlobalKey<NavigatorState>();
    final prefs = await pumpPage(
      tester,
      const AiProviderListPage(),
      pane: pane,
      blur: false,
    );
    await tester.tap(find.byKey(const ValueKey('provider_manage_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(provider.name));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(AiL10n.current.deleteSelectedProviders));
    await tester.pumpAndSettle();
    final dialogContext = tester.element(find.byType(AlertDialog));
    expect(
      ModalRoute.of(dialogContext)?.navigator,
      same(Navigator.of(dialogContext, rootNavigator: true)),
    );
    expect(
      ModalRoute.of(dialogContext)?.navigator,
      isNot(same(pane.currentState)),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.text(AiL10n.current.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(provider.name), findsOneWidget);
    expect(jsonDecode(prefs.getString('ai_providers')!), isNotEmpty);
  });
}
