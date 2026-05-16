import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiProvider state', () {
    late SharedPreferences prefs;
    late ProviderContainer container;

    Future<void> bootstrap({
      List<AiProvider> providers = const [],
      List<String> favoriteKeys = const [],
      Map<String, Object> extra = const {},
    }) async {
      SharedPreferences.setMockInitialValues({
        if (providers.isNotEmpty)
          'ai_providers': jsonEncode(providers.map((e) => e.toJson()).toList()),
        if (favoriteKeys.isNotEmpty) 'ai_favorite_model_keys': favoriteKeys,
        ...extra,
      });
      prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [
          aiSharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
    }

    AiProvider provider(
      String id, {
      bool pinned = false,
      List<AiModel> models = const [],
    }) {
      return AiProvider(
        id: id,
        name: 'Provider $id',
        type: AiProviderType.openai,
        baseUrl: 'https://example.com/$id',
        pinned: pinned,
        models: models,
      );
    }

    test('AiProvider JSON round-trip keeps pinned and legacy defaults false',
        () {
      final original = provider('p1', pinned: true);
      final restored = AiProvider.fromJson(original.toJson());
      expect(restored.pinned, isTrue);

      final legacy = AiProvider.fromJson({
        'id': 'legacy',
        'name': 'Legacy',
        'type': 'openai',
        'base_url': 'https://example.com',
        'models': const [],
      });
      expect(legacy.pinned, isFalse);
    });

    test('togglePin moves provider to top of pinned section', () async {
      await bootstrap(
        providers: [
          provider('a', pinned: true),
          provider('b'),
          provider('c'),
        ],
      );

      await container.read(aiProviderListProvider.notifier).togglePin('c');
      final ids = container
          .read(aiProviderListProvider)
          .map((item) => '${item.id}:${item.pinned}')
          .toList();
      expect(ids, ['c:true', 'a:true', 'b:false']);
    });

    test('togglePin unpins provider to end of normal section', () async {
      await bootstrap(
        providers: [
          provider('a', pinned: true),
          provider('b', pinned: true),
          provider('c'),
        ],
      );

      await container.read(aiProviderListProvider.notifier).togglePin('a');
      final ids = container
          .read(aiProviderListProvider)
          .map((item) => '${item.id}:${item.pinned}')
          .toList();
      expect(ids, ['b:true', 'c:false', 'a:false']);
    });

    test('reorderPinned and reorderUnpinned only affect their own sections',
        () async {
      await bootstrap(
        providers: [
          provider('a', pinned: true),
          provider('b', pinned: true),
          provider('c'),
          provider('d'),
        ],
      );

      final notifier = container.read(aiProviderListProvider.notifier);
      await notifier.reorderPinned(0, 1);
      await notifier.reorderUnpinned(1, 0);

      final ids = container
          .read(aiProviderListProvider)
          .map((item) => item.id)
          .toList();
      expect(ids, ['b', 'a', 'd', 'c']);
    });

    test('updateProvider keeps reordered model order in state and storage',
        () async {
      await bootstrap(
        providers: [
          provider('p', models: const [
            AiModel(id: 'model-a'),
            AiModel(id: 'model-b'),
            AiModel(id: 'model-c'),
          ]),
        ],
      );

      await container.read(aiProviderListProvider.notifier).updateProvider(
        id: 'p',
        models: const [
          AiModel(id: 'model-c'),
          AiModel(id: 'model-a'),
          AiModel(id: 'model-b'),
        ],
      );

      final stateIds = container
          .read(aiProviderListProvider)
          .single
          .models
          .map((model) => model.id)
          .toList();
      expect(stateIds, ['model-c', 'model-a', 'model-b']);

      final saved =
          jsonDecode(prefs.getString('ai_providers')!) as List<dynamic>;
      final savedModels =
          (saved.single as Map<String, dynamic>)['models'] as List<dynamic>;
      expect(
        savedModels
            .map((model) => (model as Map<String, dynamic>)['id'])
            .toList(),
        ['model-c', 'model-a', 'model-b'],
      );
    });

    test('removeProviders removes state and fallback api keys', () async {
      await bootstrap(
        providers: [
          provider('a'),
          provider('b', pinned: true),
          provider('c'),
        ],
        extra: {
          '__secure_fallback__ai_provider_key_a': 'key-a',
          '__secure_fallback__ai_provider_key_b': 'key-b',
          '__secure_fallback__ai_provider_key_c': 'key-c',
        },
      );

      await container
          .read(aiProviderListProvider.notifier)
          .removeProviders(['a', 'b']);

      final remaining = container
          .read(aiProviderListProvider)
          .map((item) => item.id)
          .toList();
      expect(remaining, ['c']);
      expect(prefs.getString('__secure_fallback__ai_provider_key_a'), isNull);
      expect(prefs.getString('__secure_fallback__ai_provider_key_b'), isNull);
      expect(prefs.getString('__secure_fallback__ai_provider_key_c'), 'key-c');
    });

    test('favorite models keep latest first and support toggle removal',
        () async {
      await bootstrap(
        providers: [
          provider('a', models: const [
            AiModel(id: 'text-a', output: [Modality.text]),
          ]),
          provider('b', models: const [
            AiModel(id: 'text-b', output: [Modality.text]),
          ]),
        ],
      );

      var keys = nextFavoriteAiModelKeys(
        container.read(favoriteAiModelKeysProvider),
        buildAiModelKey('a', 'text-a'),
      );
      await prefs.setStringList('ai_favorite_model_keys', keys);
      container.read(favoriteAiModelKeysProvider.notifier).state = keys;

      keys = nextFavoriteAiModelKeys(
        container.read(favoriteAiModelKeysProvider),
        buildAiModelKey('b', 'text-b'),
      );
      await prefs.setStringList('ai_favorite_model_keys', keys);
      container.read(favoriteAiModelKeysProvider.notifier).state = keys;

      expect(
        container.read(favoriteAiModelKeysProvider),
        ['b:text-b', 'a:text-a'],
      );

      keys = nextFavoriteAiModelKeys(
        container.read(favoriteAiModelKeysProvider),
        buildAiModelKey('a', 'text-a'),
      );
      await prefs.setStringList('ai_favorite_model_keys', keys);
      container.read(favoriteAiModelKeysProvider.notifier).state = keys;
      expect(container.read(favoriteAiModelKeysProvider), ['b:text-b']);
    });

    test('favorite model list filters invalid keys and current mode', () async {
      await bootstrap(
        providers: [
          provider('a', models: const [
            AiModel(id: 'text:a', output: [Modality.text]),
            AiModel(id: 'image-a', output: [Modality.image]),
          ]),
        ],
        favoriteKeys: ['a:image-a', 'missing:model', 'a:text:a'],
      );

      final allFavorites = container.read(allFavoriteAiModelsProvider);
      final textFavorites =
          container.read(favoriteAiModelsProvider(PromptType.text));
      final imageFavorites =
          container.read(favoriteAiModelsProvider(PromptType.image));

      expect(
        allFavorites.map((item) => item.model.id).toList(),
        ['image-a', 'text:a'],
      );
      expect(textFavorites.map((item) => item.model.id).toList(), ['text:a']);
      expect(imageFavorites.map((item) => item.model.id).toList(), ['image-a']);
    });

    test('reorder favorite keys keeps storage and provider state in sync',
        () async {
      await bootstrap(
        providers: [
          provider('a', models: const [
            AiModel(id: 'text-a', output: [Modality.text]),
          ]),
          provider('b', models: const [
            AiModel(id: 'image-b', output: [Modality.image]),
          ]),
        ],
        favoriteKeys: ['a:text-a', 'b:image-b'],
      );

      final reorderedKeys = reorderFavoriteAiModelKeyOrder(
        container.read(favoriteAiModelKeysProvider),
        ['b:image-b', 'a:text-a'],
      );

      await prefs.setStringList('ai_favorite_model_keys', reorderedKeys);
      container.read(favoriteAiModelKeysProvider.notifier).state =
          reorderedKeys;

      expect(
        prefs.getStringList('ai_favorite_model_keys'),
        ['b:image-b', 'a:text-a'],
      );
      expect(
        container.read(favoriteAiModelKeysProvider),
        ['b:image-b', 'a:text-a'],
      );
      expect(
        container
            .read(allFavoriteAiModelsProvider)
            .map((item) => item.model.id)
            .toList(),
        ['image-b', 'text-a'],
      );
    });

    test(
        'reorder helper preserves invalid keys while reordering valid favorites',
        () {
      expect(
        reorderFavoriteAiModelKeyOrder(
          ['missing:model', 'a:text-a', 'ghost:item', 'b:image-b'],
          ['b:image-b', 'a:text-a'],
        ),
        ['b:image-b', 'a:text-a', 'missing:model', 'ghost:item'],
      );
    });
  });
}
