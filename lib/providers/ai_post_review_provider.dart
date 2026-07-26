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

/// 解析「providerId:modelId」偏好并回退到默认文本模型的公共逻辑。
/// AI 审核与 AI 翻译共用,仅偏好 key 不同:显式选择优先,失效(模型被
/// 删除等)时依次回退到默认文本模型、首个可用文本模型。
({AiProvider provider, AiModel model})? resolveSelectedTextAiModel(
  Ref ref,
  String? selectedKey,
) {
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
}

final aiPostReviewSelectedModelProvider =
    Provider<({AiProvider provider, AiModel model})?>((ref) {
      final selectedKey = ref.watch(
        preferencesProvider.select((prefs) => prefs.aiPostReviewModelKey),
      );
      return resolveSelectedTextAiModel(ref, selectedKey);
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
