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
          AiModel(id: 'gamma-image', name: 'Gamma Image', output: [Modality.image]),
        ],
      ),
    ];

    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode(providers.map((e) => e.toJson()).toList()),
      'ai_favorite_model_keys': ['p1:alpha'],
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSharedPreferencesProvider.overrideWithValue(prefs),
        ],
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

  testWidgets('shows favorites dock and selecting a model closes sheet',
      (tester) async {
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
