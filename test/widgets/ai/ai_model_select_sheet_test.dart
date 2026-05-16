import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/widgets/ai/ai_model_select_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(WidgetTester tester) async {
    final providers = [
      AiProvider(
        id: 'p1',
        name: 'Provider One',
        type: AiProviderType.openai,
        baseUrl: 'https://example.com/1',
        pinned: true,
        models: const [
          AiModel(id: 'alpha', name: 'Alpha Model', output: [Modality.text]),
          AiModel(id: 'beta', name: 'Beta Model', output: [Modality.text]),
        ],
      ),
      AiProvider(
        id: 'p2',
        name: 'Provider Two',
        type: AiProviderType.openai,
        baseUrl: 'https://example.com/2',
        models: const [
          AiModel(
            id: 'gamma-image',
            name: 'Gamma Image',
            output: [Modality.image],
          ),
        ],
      ),
    ];

    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode(providers.map((e) => e.toJson()).toList()),
      'ai_favorite_model_keys': ['p1:alpha', 'p2:gamma-image'],
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiSharedPreferencesProvider.overrideWithValue(prefs)],
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const _ModelSelectTestHost(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows favorites dock and selecting a model closes sheet', (
    tester,
  ) async {
    await pumpHost(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('收藏模型'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('favorite_p1_beta')));
    await tester.pumpAndSettle();

    expect(find.text('Beta Model'), findsWidgets);

    await tester.tap(find.text('Beta Model').last);
    await tester.pumpAndSettle();

    expect(find.text('selected:beta'), findsOneWidget);
    expect(find.text('收藏模型'), findsNothing);
  });

  testWidgets('text mode favorites still show image models', (tester) async {
    await pumpHost(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final favoritesSection = find.byKey(const ValueKey('section_favorites'));
    expect(favoritesSection, findsOneWidget);
    expect(
      find.descendant(of: favoritesSection, matching: find.text('Gamma Image')),
      findsOneWidget,
    );
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byType(ReorderableDelayedDragStartListener), findsWidgets);
  });

  testWidgets('search keeps favorite match visible but disables drag', (
    tester,
  ) async {
    await pumpHost(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Gamma');
    await tester.pumpAndSettle();

    final favoritesSection = find.byKey(const ValueKey('section_favorites'));
    expect(favoritesSection, findsOneWidget);
    expect(
      find.descendant(of: favoritesSection, matching: find.text('Gamma Image')),
      findsOneWidget,
    );
    expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
  });

  testWidgets('favorite reorder persists after reopening sheet', (
    tester,
  ) async {
    await pumpHost(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final alphaRow = find.byKey(const ValueKey('favorite_row_p1_alpha'));
    final gammaRow = find.byKey(const ValueKey('favorite_row_p2_gamma-image'));
    expect(
      tester.getTopLeft(alphaRow).dy,
      lessThan(tester.getTopLeft(gammaRow).dy),
    );

    final gesture = await tester.startGesture(tester.getCenter(gammaRow));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(gammaRow).dy,
      lessThan(tester.getTopLeft(alphaRow).dy),
    );

    await tester.tap(gammaRow);
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('favorite_row_p2_gamma-image')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('favorite_row_p1_alpha')))
            .dy,
      ),
    );
  });
}

class _ModelSelectTestHost extends ConsumerStatefulWidget {
  const _ModelSelectTestHost();

  @override
  ConsumerState<_ModelSelectTestHost> createState() =>
      _ModelSelectTestHostState();
}

class _ModelSelectTestHostState extends ConsumerState<_ModelSelectTestHost> {
  String _selected = 'none';

  @override
  Widget build(BuildContext context) {
    final allModels = ref.watch(allAvailableAiModelsProvider);
    final current = allModels.first;
    return Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () async {
              final picked = await showAiModelSelectSheet(
                context: context,
                allModels: allModels,
                current: current,
                mode: PromptType.text,
              );
              if (picked != null && mounted) {
                setState(() => _selected = picked.model.id);
              }
            },
            child: const Text('open'),
          ),
          Text('selected:$_selected'),
        ],
      ),
    );
  }
}
