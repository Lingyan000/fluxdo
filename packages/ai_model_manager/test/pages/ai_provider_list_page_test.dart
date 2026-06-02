import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPage(
    WidgetTester tester, {
    required List<AiProvider> providers,
  }) async {
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode(providers.map((e) => e.toJson()).toList()),
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(
          home: AiProviderListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AiProvider provider(
    String id,
    String name, {
    bool pinned = false,
  }) {
    return AiProvider(
      id: id,
      name: name,
      type: AiProviderType.openai,
      baseUrl: 'https://example.com/$id',
      pinned: pinned,
      models: const [
        AiModel(id: 'model-a'),
      ],
    );
  }

  testWidgets('shows pinned and normal sections', (tester) async {
    await pumpPage(
      tester,
      providers: [
        provider('p1', 'Pinned One', pinned: true),
        provider('p2', 'Normal Two'),
      ],
    );

    expect(find.text('置顶提供商'), findsOneWidget);
    expect(find.text('普通提供商'), findsOneWidget);
    expect(find.text('Pinned One'), findsOneWidget);
    expect(find.text('Normal Two'), findsOneWidget);
  });

  testWidgets('manage mode allows selecting providers', (tester) async {
    await pumpPage(
      tester,
      providers: [
        provider('p1', 'Pinned One', pinned: true),
        provider('p2', 'Normal Two'),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('provider_manage_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Normal Two'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 个供应商'), findsOneWidget);
  });

  testWidgets('provider cells disable long press menu for drag sorting', (
    tester,
  ) async {
    await pumpPage(
      tester,
      providers: [
        provider('p1', 'Pinned One', pinned: true),
        provider('p2', 'Normal Two'),
      ],
    );

    final cell = tester.widget<SwipeActionCell>(find.byType(SwipeActionCell).first);

    expect(cell.enableLongPressMenu, isFalse);
  });
}
