import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('models tab reorder callback persists duplicate model ids',
      (tester) async {
    final provider = AiProvider(
      id: 'provider-1',
      name: 'Test Provider',
      type: AiProviderType.openai,
      baseUrl: 'https://example.com',
      models: const [
        AiModel(id: 'duplicate', name: 'Model A'),
        AiModel(id: 'duplicate', name: 'Model B'),
        AiModel(id: 'model-c', name: 'Model C'),
      ],
    );

    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
      '__secure_fallback__ai_provider_key_provider-1': 'test-key',
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          home: AiProviderEditPage(provider: provider),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(2), 'test-key');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.layers_outlined));
    await tester.pumpAndSettle();

    final modelAFinder = find.text('Model A');
    final modelCFinder = find.text('Model C');
    expect(modelAFinder, findsOneWidget);
    expect(modelCFinder, findsOneWidget);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNWidgets(3));

    final reorderableList =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    reorderableList.onReorderItem!(2, 0);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(modelCFinder).dy,
      lessThan(tester.getTopLeft(modelAFinder).dy),
    );

    await tester.tap(find.text('保存'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = jsonDecode(prefs.getString('ai_providers')!) as List<dynamic>;
    final savedModels =
        (saved.single as Map<String, dynamic>)['models'] as List<dynamic>;
    expect(
      savedModels
          .map((model) => (model as Map<String, dynamic>)['name'])
          .toList(),
      ['Model C', 'Model A', 'Model B'],
    );
  });
}
