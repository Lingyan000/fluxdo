import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ai_post_review_service.dart';
import 'core_providers.dart';
import 'preferences_provider.dart';
import 'theme_provider.dart';

final aiPostReviewAvailableModelsProvider =
    Provider<List<({AiProvider provider, AiModel model})>>((ref) {
      final allModels = ref.watch(allAvailableAiModelsProvider);
      return allModels
          .where((item) => item.model.output.contains(Modality.text))
          .toList(growable: false);
    });

final aiPostReviewSelectedModelProvider =
    Provider<({AiProvider provider, AiModel model})?>((ref) {
      final selectedKey = ref.watch(
        preferencesProvider.select((prefs) => prefs.aiPostReviewModelKey),
      );
      final available = ref.watch(aiPostReviewAvailableModelsProvider);
      if (available.isEmpty) return null;

      final parsed = parseAiModelKey(selectedKey);
      if (parsed != null) {
        final selected = available.firstWhereOrNull(
          (item) =>
              item.provider.id == parsed.providerId &&
              item.model.id == parsed.modelId,
        );
        if (selected != null) return selected;
      }

      final defaultTextModel = ref.watch(defaultTextAiModelProvider);
      if (defaultTextModel != null &&
          defaultTextModel.model.output.contains(Modality.text)) {
        return defaultTextModel;
      }
      return available.first;
    });

final aiPostReviewServiceProvider = Provider<AiPostReviewService>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final chatService = ref.watch(aiChatServiceProvider);
  final discourseService = ref.watch(discourseServiceProvider);
  return AiPostReviewService(
    prefs: prefs,
    chatService: chatService,
    dio: discourseService.dio,
    apiKeyLoader: AiProviderListNotifier.getApiKey,
  );
});
