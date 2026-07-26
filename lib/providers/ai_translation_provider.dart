import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ai_translation_service.dart';
import 'ai_post_review_provider.dart';
import 'locale_provider.dart';
import 'preferences_provider.dart';

/// 可选目标语言（代码 → 本语言显示名）。
const aiTranslationLanguages = <String, String>{
  'zh-CN': '简体中文',
  'zh-TW': '繁體中文',
  'en': 'English',
  'ja': '日本語',
  'ko': '한국어',
  'fr': 'Français',
  'de': 'Deutsch',
  'es': 'Español',
  'ru': 'Русский',
};

/// 偏好优先；未设置时跟随应用语言。
final aiTranslationTargetLanguageProvider = Provider<String>((ref) {
  final preferred = ref.watch(
    preferencesProvider.select((p) => p.aiTranslationTargetLanguage),
  );
  if (preferred != null && preferred.isNotEmpty) return preferred;
  final locale = ref.watch(localeProvider);
  final tag = locale?.toLanguageTag() ?? 'zh-CN';
  if (tag.startsWith('zh')) {
    return tag.contains('TW') || tag.contains('HK') || tag.contains('Hant')
        ? 'zh-TW'
        : 'zh-CN';
  }
  final short = tag.split('-').first;
  return aiTranslationLanguages.containsKey(short) ? short : 'en';
});

String aiTranslationLanguageLabel(String code) =>
    aiTranslationLanguages[code] ?? code;

/// 偏好指定模型优先，否则使用默认文本模型或首个可用文本模型
/// （回退逻辑与 AI 审核共用 [resolveSelectedTextAiModel]）。
final aiTranslationSelectedModelProvider =
    Provider<({AiProvider provider, AiModel model})?>((ref) {
      final selectedKey = ref.watch(
        preferencesProvider.select((prefs) => prefs.aiTranslationModelKey),
      );
      return resolveSelectedTextAiModel(ref, selectedKey);
    });

final aiTranslationServiceProvider = Provider<AiTranslationService>((ref) {
  final chatService = ref.watch(aiChatServiceProvider);
  return AiTranslationService(chatService: chatService);
});
