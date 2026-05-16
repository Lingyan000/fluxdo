import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_chat_attachment.dart';
import '../models/ai_provider.dart';
import '../models/ai_chat_message.dart';
import '../models/prompt_preset.dart';
import '../services/ai_chat_service.dart';
import '../services/ai_chat_storage_service.dart';
import '../services/dio_http_bridge.dart';
import 'ai_provider_providers.dart';

const _lastUsedAiAssistantModelKey = 'ai_assistant_last_model';
const _favoriteAiModelKeys = 'ai_favorite_model_keys';
// 文本 / 图像两种模式各自的"上次使用模型"key。
// 用户切换模式时聊天页会自动应用对应 mode 的模型，不再让两种模式互相覆盖。
const _lastUsedTextAiModelKey = 'ai_assistant_last_text_model';
const _lastUsedImageAiModelKey = 'ai_assistant_last_image_model';

String buildAiModelKey(String providerId, String modelId) =>
    '$providerId:$modelId';

({String providerId, String modelId})? parseAiModelKey(String? key) {
  if (key == null || key.isEmpty) return null;
  final parts = key.split(':');
  if (parts.length < 2) return null;
  return (
    providerId: parts.first,
    modelId: parts.sublist(1).join(':'),
  );
}

({AiProvider provider, AiModel model})? _findAiModelByKey(
  List<({AiProvider provider, AiModel model})> all,
  String? key,
) {
  final parsed = parseAiModelKey(key);
  if (parsed == null) return null;

  for (final item in all) {
    if (item.provider.id == parsed.providerId &&
        item.model.id == parsed.modelId) {
      return item;
    }
  }
  return null;
}

/// 所有可用的 AI 模型列表（供应商 + 模型）
final allAvailableAiModelsProvider =
    Provider<List<({AiProvider provider, AiModel model})>>(
  (ref) {
    final providers = ref.watch(aiProviderListProvider);
    final result = <({AiProvider provider, AiModel model})>[];
    for (final provider in providers) {
      for (final model in provider.models) {
        if (model.enabled) {
          result.add((provider: provider, model: model));
        }
      }
    }
    return result;
  },
);

/// 默认/首选的 AI 模型（通用）
///
/// 取通用 default key；找不到时退到 allModels.first。
final defaultAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;

    final defaultKey = ref.watch(defaultAiModelKeyProvider);
    return _findAiModelByKey(all, defaultKey) ?? all.first;
  },
);

/// 文本模式默认模型
///
/// 优先级：用户设的文本默认 → 通用默认（如果其 modality 是 text）→
/// allModels 中第一个含 text output 的模型
final defaultTextAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;
    final key = ref.watch(defaultTextAiModelKeyProvider);
    final explicit = _findAiModelByKey(all, key);
    if (explicit != null) return explicit;
    final generic = ref.watch(defaultAiModelProvider);
    if (generic != null && generic.model.output.contains(Modality.text)) {
      return generic;
    }
    for (final m in all) {
      if (m.model.output.contains(Modality.text)) return m;
    }
    return null;
  },
);

/// 图像模式默认模型
final defaultImageAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;
    final key = ref.watch(defaultImageAiModelKeyProvider);
    final explicit = _findAiModelByKey(all, key);
    if (explicit != null) return explicit;
    final generic = ref.watch(defaultAiModelProvider);
    if (generic != null && generic.model.output.contains(Modality.image)) {
      return generic;
    }
    for (final m in all) {
      if (m.model.output.contains(Modality.image)) return m;
    }
    return null;
  },
);

/// AI 助手上次使用的模型 key（providerId:modelId）
final lastUsedAiAssistantModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_lastUsedAiAssistantModelKey);
});

/// 收藏模型 key 列表，按最近收藏在前排序。
final favoriteAiModelKeysProvider = StateProvider<List<String>>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getStringList(_favoriteAiModelKeys) ?? const [];
});

/// 全量收藏模型列表，保持持久化顺序，不按模式过滤。
final allFavoriteAiModelsProvider =
    Provider<List<({AiProvider provider, AiModel model})>>((ref) {
  final all = ref.watch(allAvailableAiModelsProvider);
  final keys = ref.watch(favoriteAiModelKeysProvider);

  return [
    for (final key in keys)
      if (_findAiModelByKey(all, key) case final item?) item,
  ];
});

/// 当前模式下可见的收藏模型列表。
final favoriteAiModelsProvider =
    Provider.family<List<({AiProvider provider, AiModel model})>, PromptType>(
        (ref, mode) {
  final favorites = ref.watch(allFavoriteAiModelsProvider);
  bool matchesMode(AiModel model) => mode == PromptType.image
      ? model.output.contains(Modality.image)
      : model.output.contains(Modality.text);

  return [
    for (final item in favorites)
      if (matchesMode(item.model)) item,
  ];
});

List<String> nextFavoriteAiModelKeys(List<String> current, String key) {
  final next = [...current];
  if (next.contains(key)) {
    next.removeWhere((value) => value == key);
  } else {
    next
      ..removeWhere((value) => value == key)
      ..insert(0, key);
  }
  return next;
}

List<String> reorderFavoriteAiModelKeyOrder(
  List<String> current,
  List<String> orderedKeys,
) {
  final currentSet = current.toSet();
  final nextOrdered = <String>[];
  final seen = <String>{};

  for (final key in orderedKeys) {
    if (currentSet.contains(key) && seen.add(key)) {
      nextOrdered.add(key);
    }
  }

  final reorderedSet = nextOrdered.toSet();
  return [
    ...nextOrdered,
    for (final key in current)
      if (!reorderedSet.contains(key)) key,
  ];
}

Future<void> toggleFavoriteAiModel(
  WidgetRef ref,
  String providerId,
  String modelId,
) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  final key = buildAiModelKey(providerId, modelId);
  final next = nextFavoriteAiModelKeys(
    ref.read(favoriteAiModelKeysProvider),
    key,
  );
  await prefs.setStringList(_favoriteAiModelKeys, next);
  ref.read(favoriteAiModelKeysProvider.notifier).state = next;
}

Future<void> reorderFavoriteAiModelKeys(
  WidgetRef ref,
  List<String> orderedKeys,
) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  final next = reorderFavoriteAiModelKeyOrder(
    ref.read(favoriteAiModelKeysProvider),
    orderedKeys,
  );
  await prefs.setStringList(_favoriteAiModelKeys, next);
  ref.read(favoriteAiModelKeysProvider.notifier).state = next;
}

/// AI 助手上次使用的模型
final lastUsedAiAssistantModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;

    final lastUsedKey = ref.watch(lastUsedAiAssistantModelKeyProvider);
    return _findAiModelByKey(all, lastUsedKey);
  },
);

/// 设置 AI 助手上次使用的模型
///
/// 同时把模型写到对应模式（text/image）的"上次使用"key，
/// 让用户切换模式时能自动恢复上次该模式的模型。
Future<void> setLastUsedAiAssistantModel(
  WidgetRef ref,
  String providerId,
  String modelId, {
  /// 模型属于的模式。null = 不区分模式（仅写通用 key，向后兼容）；
  /// 非 null = 同时写通用 key 和模式专属 key。
  ///
  /// 调用方一般用 `model.output.contains(Modality.image)` 判断后传入。
  bool? isImageMode,
}) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  final key = buildAiModelKey(providerId, modelId);
  await prefs.setString(_lastUsedAiAssistantModelKey, key);
  ref.read(lastUsedAiAssistantModelKeyProvider.notifier).state = key;
  if (isImageMode == true) {
    await prefs.setString(_lastUsedImageAiModelKey, key);
    ref.read(lastUsedImageAiModelKeyProvider.notifier).state = key;
  } else if (isImageMode == false) {
    await prefs.setString(_lastUsedTextAiModelKey, key);
    ref.read(lastUsedTextAiModelKeyProvider.notifier).state = key;
  }
}

/// 文本模式上次使用的模型 key
final lastUsedTextAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_lastUsedTextAiModelKey);
});

/// 文本模式上次使用的模型
final lastUsedTextAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;
    final key = ref.watch(lastUsedTextAiModelKeyProvider);
    return _findAiModelByKey(all, key);
  },
);

/// 图像模式上次使用的模型 key
final lastUsedImageAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_lastUsedImageAiModelKey);
});

/// 图像模式上次使用的模型
final lastUsedImageAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;
    final key = ref.watch(lastUsedImageAiModelKeyProvider);
    return _findAiModelByKey(all, key);
  },
);

/// 第一个可用的 AI 模型（向后兼容）
final firstAvailableAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) => ref.watch(defaultAiModelProvider),
);

/// 是否有可用的 AI 模型
final hasAvailableAiModelProvider = Provider<bool>(
  (ref) => ref.watch(allAvailableAiModelsProvider).isNotEmpty,
);

/// 话题选中的 AI 模型（独立管理，避免切换时影响消息列表）
final topicSelectedAiModelProvider = StateProvider.autoDispose
    .family<({AiProvider provider, AiModel model})?, int>(
  (ref, topicId) => null, // null 表示使用记忆模型或默认模型
);

/// AI 聊天服务
final aiChatServiceProvider = Provider((ref) {
  final useAppNetwork = ref.watch(aiUseAppNetworkProvider);
  final adapterFactory = ref.watch(aiDioAdapterFactoryProvider);
  final enablePartialImages = ref.watch(aiPartialImagesProvider);
  if (useAppNetwork && adapterFactory != null) {
    return AiChatService(
      bridgedClient: DioBackedHttpClient(adapterFactory()),
      enablePartialImages: enablePartialImages,
    );
  }
  return AiChatService(enablePartialImages: enablePartialImages);
});

/// 标题生成模型 key（providerId:modelId）
final aiTitleModelKeyProvider = StateProvider<String?>((ref) {
  final storageService = ref.watch(aiChatStorageServiceProvider);
  return storageService.getTitleModelKey();
});

/// 标题生成模型
final aiTitleModelProvider = Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;

    final key = ref.watch(aiTitleModelKeyProvider);
    return _findAiModelByKey(all, key);
  },
);

/// 设置标题生成模型
Future<void> setAiTitleModel(
    WidgetRef ref, String? providerId, String? modelId) async {
  final storageService = ref.read(aiChatStorageServiceProvider);
  if (providerId == null || modelId == null) {
    await storageService.setTitleModelKey(null);
    ref.read(aiTitleModelKeyProvider.notifier).state = null;
  } else {
    final key = '$providerId:$modelId';
    await storageService.setTitleModelKey(key);
    ref.read(aiTitleModelKeyProvider.notifier).state = key;
  }
}

/// 图像 prompt 优化模型 key（providerId:modelId）
/// 调 image gen 模型前先用这个聊天模型把话题上下文+用户简短指令
/// 翻译成精炼的 image prompt。未配置则降级直接拼接上下文。
final aiImagePromptOptimizerModelKeyProvider = StateProvider<String?>((ref) {
  final storageService = ref.watch(aiChatStorageServiceProvider);
  return storageService.getImagePromptOptimizerModelKey();
});

/// 图像 prompt 优化模型
final aiImagePromptOptimizerModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;
    final key = ref.watch(aiImagePromptOptimizerModelKeyProvider);
    return _findAiModelByKey(all, key);
  },
);

/// 设置图像 prompt 优化模型
Future<void> setAiImagePromptOptimizerModel(
    WidgetRef ref, String? providerId, String? modelId) async {
  final storageService = ref.read(aiChatStorageServiceProvider);
  if (providerId == null || modelId == null) {
    await storageService.setImagePromptOptimizerModelKey(null);
    ref.read(aiImagePromptOptimizerModelKeyProvider.notifier).state = null;
  } else {
    final key = '$providerId:$modelId';
    await storageService.setImagePromptOptimizerModelKey(key);
    ref.read(aiImagePromptOptimizerModelKeyProvider.notifier).state = key;
  }
}

/// 话题 AI 上下文范围（独立管理，避免切换时影响消息列表滚动）
final topicAiContextScopeProvider = StateProvider.autoDispose
    .family<ContextScope, int>((ref, topicId) => ContextScope.first5);

/// 话题 AI 聊天状态
class TopicAiChatState {
  final List<AiChatMessage> messages;
  final bool isGenerating;
  final String? currentSessionId;
  final List<AiChatSession> sessions;

  const TopicAiChatState({
    this.messages = const [],
    this.isGenerating = false,
    this.currentSessionId,
    this.sessions = const [],
  });

  TopicAiChatState copyWith({
    List<AiChatMessage>? messages,
    bool? isGenerating,
    String? currentSessionId,
    List<AiChatSession>? sessions,
  }) {
    return TopicAiChatState(
      messages: messages ?? this.messages,
      isGenerating: isGenerating ?? this.isGenerating,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      sessions: sessions ?? this.sessions,
    );
  }
}

/// 话题帖子数据接口（避免直接依赖 Topic 模型）
class TopicContext {
  final String title;
  final List<TopicPostContext> posts;

  const TopicContext({required this.title, required this.posts});
}

class TopicPostContext {
  final int postNumber;
  final String username;
  final String cooked; // HTML 内容

  const TopicPostContext({
    required this.postNumber,
    required this.username,
    required this.cooked,
  });
}

/// 获取上下文帖子的回调类型
/// 返回指定范围的帖子列表，由外部（使用 DiscourseService）实现
typedef ContextPostsFetcher = Future<List<TopicPostContext>> Function(
  int topicId,
  ContextScope scope,
);

/// 话题 AI 聊天状态管理（per-topic，autoDispose）
final topicAiChatProvider = StateNotifierProvider.autoDispose
    .family<TopicAiChatNotifier, TopicAiChatState, int>(
  (ref, topicId) {
    final chatService = ref.watch(aiChatServiceProvider);
    final storageService = ref.watch(aiChatStorageServiceProvider);
    final titleModel = ref.read(aiTitleModelProvider);
    final imagePromptOptimizerModel =
        ref.read(aiImagePromptOptimizerModelProvider);
    final notifier = TopicAiChatNotifier(
      chatService: chatService,
      storageService: storageService,
      topicId: topicId,
      titleModel: titleModel,
      imagePromptOptimizerModel: imagePromptOptimizerModel,
    );
    ref.onDispose(() {
      notifier.saveBeforeDispose();
    });
    return notifier;
  },
);

class TopicAiChatNotifier extends StateNotifier<TopicAiChatState> {
  static const _uuid = Uuid();

  final AiChatService chatService;
  final AiChatStorageService storageService;
  final int topicId;
  final ({AiProvider provider, AiModel model})? titleModel;
  final ({AiProvider provider, AiModel model})? imagePromptOptimizerModel;

  StreamSubscription<AiChatChunk>? _streamSubscription;
  http.Client? _requestClient;
  bool _cancelled = false;
  bool _isGeneratingTitle = false;

  /// 缓存的上下文帖子（通过 fetchContextPosts 加载）
  List<TopicPostContext>? _cachedContextPosts;
  String? _cachedTitle;

  TopicAiChatNotifier({
    required this.chatService,
    required this.storageService,
    required this.topicId,
    this.titleModel,
    this.imagePromptOptimizerModel,
  }) : super(const TopicAiChatState()) {
    _loadFromStorage();
  }

  /// 从存储加载：读取话题会话列表，默认加载最新会话
  void _loadFromStorage() {
    final sessions = storageService.getTopicSessions(topicId);
    if (sessions.isEmpty) return;

    final latestSession = sessions.first;
    final messages = storageService.loadSessionMessages(latestSession.id);
    state = state.copyWith(
      sessions: sessions,
      currentSessionId: latestSession.id,
      messages: messages,
    );
  }

  /// 保存当前消息到存储
  Future<void> _saveToStorage() async {
    final sessionId = state.currentSessionId;
    if (sessionId == null) return;
    await storageService.saveSessionMessages(
      topicId,
      sessionId,
      state.messages,
      topicTitle: _cachedTitle,
    );
    // 刷新会话列表
    state = state.copyWith(sessions: storageService.getTopicSessions(topicId));
  }

  /// dispose 前保存（由 ref.onDispose 调用）
  void saveBeforeDispose() {
    final sessionId = state.currentSessionId;
    if (sessionId == null || state.messages.isEmpty) return;
    storageService.saveSessionMessages(
      topicId,
      sessionId,
      state.messages,
      topicTitle: _cachedTitle,
    );
  }

  /// 创建新会话
  void createNewSession() {
    stopGeneration();
    final sessionId = _uuid.v4();
    state = state.copyWith(
      currentSessionId: sessionId,
      messages: [],
    );
  }

  /// 切换到指定会话
  void switchSession(String sessionId) {
    if (sessionId == state.currentSessionId) return;
    stopGeneration();
    final messages = storageService.loadSessionMessages(sessionId);
    state = state.copyWith(
      currentSessionId: sessionId,
      messages: messages,
    );
  }

  /// 删除指定会话
  Future<void> deleteSession(String sessionId) async {
    await storageService.deleteSession(topicId, sessionId);
    final sessions = storageService.getTopicSessions(topicId);

    if (sessionId == state.currentSessionId) {
      // 删除的是当前会话，切换到最新的或清空
      if (sessions.isNotEmpty) {
        final latest = sessions.first;
        final messages = storageService.loadSessionMessages(latest.id);
        state = state.copyWith(
          sessions: sessions,
          currentSessionId: latest.id,
          messages: messages,
        );
      } else {
        state = const TopicAiChatState();
      }
    } else {
      state = state.copyWith(sessions: sessions);
    }
  }

  /// 设置上下文帖子缓存（由外部在加载完成后调用）
  void setContextPosts(String title, List<TopicPostContext> posts) {
    _cachedTitle = title;
    _cachedContextPosts = posts;
  }

  /// 发送消息
  ///
  /// [imageAspect] 仅图像生成路径有效：'1:1' / '16:9' / '9:16' / '4:3' / '3:4'，
  /// 由调用方（PromptPreset 维度面板或编辑页 aspectRatio 字段）传入。
  Future<void> sendMessage(
    String content,
    ContextScope contextScope, {
    required ({AiProvider provider, AiModel model}) selectedModel,
    List<AiChatAttachment>? attachments,
    ThinkingConfig thinkingConfig = const ThinkingConfig(),
    String? imageAspect,
  }) async {
    if (content.trim().isEmpty &&
        (attachments == null || attachments.isEmpty)) {
      return;
    }

    _cancelled = false;

    // 确保有当前会话
    state = state.copyWith(
      currentSessionId: state.currentSessionId ?? _uuid.v4(),
    );

    // 添加用户消息
    final userMessage = AiChatMessage(
      id: _uuid.v4(),
      role: ChatRole.user,
      content: content.trim(),
      createdAt: DateTime.now(),
      attachments: attachments,
    );

    // 添加 AI 占位消息
    // 图像生成模型（output 含 image）会预先标记，UI 在第一帧到达前就能显示
    // 「正在生成图片」占位（带 shimmer + 计时）
    final isImageGen = selectedModel.model.output.contains(Modality.image);
    final assistantMessage = AiChatMessage(
      id: _uuid.v4(),
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.now(),
      status: MessageStatus.streaming,
      isImageGeneration: isImageGen,
    );

    state = state.copyWith(
      messages: [...state.messages, userMessage, assistantMessage],
      isGenerating: true,
    );

    try {
      // 获取 API Key
      final apiKey =
          await AiProviderListNotifier.getApiKey(selectedModel.provider.id);
      if (!mounted) return;
      if (apiKey == null) {
        _updateAssistantMessage(
          assistantMessage.id,
          content: '',
          status: MessageStatus.error,
          errorMessage: AiL10n.current.apiKeyNotFoundError,
        );
        state = state.copyWith(isGenerating: false);
        return;
      }

      // 构建上下文
      final topicContext = _cachedContextPosts != null && _cachedTitle != null
          ? TopicContext(title: _cachedTitle!, posts: _cachedContextPosts!)
          : null;

      // 构建消息列表
      final chatMessages = _buildChatMessages(topicContext, contextScope);

      // 图像生成路径
      final isImageGeneration =
          selectedModel.model.output.contains(Modality.image);
      final rawImageContext = isImageGeneration && topicContext != null
          ? _buildImageContextSummary(topicContext, contextScope)
          : null;

      // 两步生成：如果配了 imagePromptOptimizerModel，先调聊天模型把
      // (话题上下文 + 用户简短指令) 翻译成精炼的 image prompt。
      // 失败 / 未配置则降级使用 rawImageContext 直接拼接。
      List<AiChatMessage> messagesForGen = chatMessages;
      String? imagePromptContext = rawImageContext;
      if (isImageGeneration &&
          imagePromptOptimizerModel != null &&
          rawImageContext != null) {
        _updateAssistantMessage(
          assistantMessage.id,
          content: '',
          status: MessageStatus.streaming,
          loadingStage: 'optimizing_prompt',
        );
        try {
          final refined = await _refineImagePrompt(
            contextSummary: rawImageContext,
            userPrompt: content.trim(),
            optimizer: imagePromptOptimizerModel!,
          );
          if (_cancelled || !mounted) return;
          if (refined.isNotEmpty) {
            // 用 refined prompt 替换最后一条 user content，
            // 同时把 imagePromptContext 设为 null（避免双重拼接）
            messagesForGen = _replaceLastUserContent(chatMessages, refined);
            imagePromptContext = null;
            // 把 refined prompt 写到 message，UI 用折叠块展示让用户验证
            _updateAssistantMessage(
              assistantMessage.id,
              content: '',
              status: MessageStatus.streaming,
              loadingStage: 'generating_image',
              optimizedPrompt: refined,
              optimizerModelName: imagePromptOptimizerModel!.model.name ??
                  imagePromptOptimizerModel!.model.id,
            );
          } else {
            _updateAssistantMessage(
              assistantMessage.id,
              content: '',
              status: MessageStatus.streaming,
              loadingStage: 'generating_image',
            );
          }
        } catch (_) {
          // fallback：optimizer 失败不影响生图，沿用 rawImageContext 拼接
          _updateAssistantMessage(
            assistantMessage.id,
            content: '',
            status: MessageStatus.streaming,
            loadingStage: 'generating_image',
          );
        }
      }

      // 为本次请求创建独立 HTTP client，stop 时 close 可立即断开连接
      _requestClient = http.Client();
      final stream = chatService.sendChatStream(
        provider: selectedModel.provider,
        model: selectedModel.model.id,
        apiKey: apiKey,
        messages: messagesForGen,
        systemPrompt: _buildSystemPrompt(topicContext),
        thinkingConfig: thinkingConfig,
        imagePromptContext: imagePromptContext,
        imageAspect: imageAspect,
        requestClient: _requestClient,
      );

      final textBuffer = StringBuffer();
      final thinkingBuffer = StringBuffer();
      final generatedImages = <AiChatAttachment>[];
      int? promptTokens;
      int? responseTokens;
      int? cachedTokens;

      _streamSubscription = stream.listen(
        (chunk) {
          if (_cancelled || !mounted) return;
          switch (chunk) {
            case final TextDelta d:
              textBuffer.write(d.text);
              _updateAssistantMessage(
                assistantMessage.id,
                content: textBuffer.toString(),
                status: MessageStatus.streaming,
                thinkingContent:
                    thinkingBuffer.isEmpty ? null : thinkingBuffer.toString(),
                attachments: generatedImages.isEmpty
                    ? null
                    : List.unmodifiable(generatedImages),
              );
            case final ThinkingDelta d:
              thinkingBuffer.write(d.text);
              _updateAssistantMessage(
                assistantMessage.id,
                content: textBuffer.toString(),
                status: MessageStatus.streaming,
                thinkingContent: thinkingBuffer.toString(),
                attachments: generatedImages.isEmpty
                    ? null
                    : List.unmodifiable(generatedImages),
              );
            case final ImageGenerated img:
              if (img.isPartial) {
                // 渐进帧：按 partialImageIndex 替换，没有就 append
                final newAtt = AiChatAttachment(
                  mimeType: img.mimeType,
                  localPath: img.localPath,
                  partialImageIndex: img.partialImageIndex,
                );
                final existingIdx = generatedImages.indexWhere(
                  (a) => a.partialImageIndex == img.partialImageIndex,
                );
                if (existingIdx >= 0) {
                  // 同一个 partial slot 的更高保真版本，覆盖旧的
                  _deletePartialFile(generatedImages[existingIdx]);
                  generatedImages[existingIdx] = newAtt;
                } else {
                  generatedImages.add(newAtt);
                }
              } else {
                // 终态图：清掉所有 partial 帧（包括其本地文件），加入终态
                for (final a in generatedImages.where((a) => a.isPartial)) {
                  _deletePartialFile(a);
                }
                generatedImages.removeWhere((a) => a.isPartial);
                generatedImages.add(AiChatAttachment(
                  mimeType: img.mimeType,
                  localPath: img.localPath,
                ));
              }
              _updateAssistantMessage(
                assistantMessage.id,
                content: textBuffer.toString(),
                status: MessageStatus.streaming,
                thinkingContent:
                    thinkingBuffer.isEmpty ? null : thinkingBuffer.toString(),
                attachments: List.unmodifiable(generatedImages),
              );
            case final UsageReport u:
              promptTokens = u.promptTokens;
              responseTokens = u.responseTokens;
              cachedTokens = u.cachedTokens;
          }
        },
        onDone: () {
          _requestClient = null;
          if (!mounted) return;
          // onDone 时清理残留 partial（如果流提前结束没收到 final，
          // 把最后一张草图升级为终态，避免持久化 partial）
          final finalized = <AiChatAttachment>[];
          for (final a in generatedImages) {
            if (a.isPartial) {
              // 升级为终态（去掉 partialImageIndex），以便持久化与 UI 不再显示草图角标
              finalized.add(a.copyWith().withoutPartialIndex());
            } else {
              finalized.add(a);
            }
          }
          // 图像模型可能正文为空但 attachments 有内容，也算成功
          final hasOutput = textBuffer.isNotEmpty ||
              thinkingBuffer.isNotEmpty ||
              finalized.isNotEmpty;
          if (!hasOutput) {
            _updateAssistantMessage(
              assistantMessage.id,
              content: '',
              status: MessageStatus.error,
              errorMessage: AiL10n.current.emptyResponseError,
            );
          } else {
            _updateAssistantMessage(
              assistantMessage.id,
              content: textBuffer.toString(),
              status: MessageStatus.completed,
              thinkingContent:
                  thinkingBuffer.isEmpty ? null : thinkingBuffer.toString(),
              attachments:
                  finalized.isEmpty ? null : List.unmodifiable(finalized),
              promptTokens: promptTokens,
              responseTokens: responseTokens,
              cachedTokens: cachedTokens,
            );
            _saveToStorage();
            _tryGenerateTitle();
          }
          state = state.copyWith(isGenerating: false);
        },
        onError: (error) {
          if (!mounted) return;
          _updateAssistantMessage(
            assistantMessage.id,
            content: textBuffer.toString(),
            status: MessageStatus.error,
            errorMessage: error.toString(),
            attachments: generatedImages.isEmpty
                ? null
                : List.unmodifiable(generatedImages),
          );
          state = state.copyWith(isGenerating: false);
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      _updateAssistantMessage(
        assistantMessage.id,
        content: '',
        status: MessageStatus.error,
        errorMessage: e.toString(),
      );
      state = state.copyWith(isGenerating: false);
    }
  }

  /// 停止生成
  void stopGeneration() {
    _cancelled = true;
    _streamSubscription?.cancel();
    _streamSubscription = null;
    _requestClient?.close();
    _requestClient = null;

    if (!mounted) return;

    // 将最后一条 streaming 消息标记为 completed
    final messages = [...state.messages];
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].status == MessageStatus.streaming) {
        messages[i] = messages[i].copyWith(status: MessageStatus.completed);
        break;
      }
    }
    state = state.copyWith(messages: messages, isGenerating: false);
  }

  /// 清空当前会话的消息
  void clearMessages() {
    stopGeneration();
    final sessionId = state.currentSessionId;
    if (sessionId != null) {
      storageService.deleteSession(topicId, sessionId);
    }
    final sessions = storageService.getTopicSessions(topicId);
    state = state.copyWith(
      messages: [],
      currentSessionId: null,
      sessions: sessions,
    );
  }

  /// 重试最后一条失败消息
  void retryLastMessage(
    ContextScope contextScope, {
    required ({AiProvider provider, AiModel model}) selectedModel,
  }) {
    final messages = [...state.messages];
    if (messages.length < 2) return;

    // 找到最后的 error 消息和它前面的用户消息
    final lastMsg = messages.last;
    if (lastMsg.status != MessageStatus.error) return;

    // 移除最后两条消息（用户消息 + AI 错误消息）
    final userContent = messages[messages.length - 2].content;
    messages.removeRange(messages.length - 2, messages.length);
    state = state.copyWith(messages: messages);

    // 重新发送
    sendMessage(userContent, contextScope, selectedModel: selectedModel);
  }

  void _updateAssistantMessage(
    String messageId, {
    required String content,
    required MessageStatus status,
    String? errorMessage,
    String? thinkingContent,
    List<AiChatAttachment>? attachments,
    int? promptTokens,
    int? responseTokens,
    int? cachedTokens,
    String? loadingStage,
    String? optimizedPrompt,
    String? optimizerModelName,
  }) {
    if (!mounted) return;
    final messages = state.messages.map((m) {
      if (m.id == messageId) {
        return m.copyWith(
          content: content,
          status: status,
          errorMessage: errorMessage,
          thinkingContent: thinkingContent,
          attachments: attachments,
          promptTokens: promptTokens,
          responseTokens: responseTokens,
          cachedTokens: cachedTokens,
          loadingStage: loadingStage,
          optimizedPrompt: optimizedPrompt,
          optimizerModelName: optimizerModelName,
        );
      }
      return m;
    }).toList();
    state = state.copyWith(messages: messages);
  }

  /// 构建系统提示
  String _buildSystemPrompt(TopicContext? topicContext) {
    final l10n = AiL10n.current;
    final buffer = StringBuffer();
    buffer.writeln(l10n.systemPromptIntro);
    if (topicContext != null) {
      buffer.writeln(l10n.systemPromptTopicTitle(topicContext.title));
      buffer.writeln(l10n.systemPromptContextHint);
    }
    buffer.writeln(l10n.systemPromptMarkdown);
    return buffer.toString();
  }

  /// 构建聊天消息列表（包含上下文）
  List<AiChatMessage> _buildChatMessages(
    TopicContext? topicContext,
    ContextScope contextScope,
  ) {
    final result = <AiChatMessage>[];
    final now = DateTime.now();

    // 注入上下文：用一对 user/assistant 消息把帖子上下文塞进对话历史
    // 这种 hack 对所有 provider 都有效，避免 systemPrompt 过长被截断
    if (topicContext != null) {
      final contextText = _buildContextText(topicContext, contextScope);
      if (contextText.isNotEmpty) {
        result.add(AiChatMessage(
          id: 'context-user',
          role: ChatRole.user,
          content: AiL10n.current.contextContentPrefix(contextText),
          createdAt: now,
        ));
        result.add(AiChatMessage(
          id: 'context-assistant',
          role: ChatRole.assistant,
          content: AiL10n.current.contextReadyResponse,
          createdAt: now,
        ));
      }
    }

    // 添加历史消息（排除 system 和空 assistant 消息）
    for (final msg in state.messages) {
      if (msg.role == ChatRole.system) continue;
      if (msg.content.isEmpty &&
          msg.role == ChatRole.assistant &&
          (msg.attachments == null || msg.attachments!.isEmpty)) {
        continue;
      }
      result.add(msg);
    }

    return result;
  }

  /// 用聊天模型把 (话题上下文 + 用户简短指令) 翻译成精炼的 image prompt。
  /// 限制 ≤ 200 词，视觉化 + 风格关键词，避免在图中嵌入文字。
  /// 10s timeout；失败抛错由调用方 catch 后 fallback。
  Future<String> _refineImagePrompt({
    required String contextSummary,
    required String userPrompt,
    required ({AiProvider provider, AiModel model}) optimizer,
  }) async {
    final apiKey =
        await AiProviderListNotifier.getApiKey(optimizer.provider.id);
    if (apiKey == null) throw Exception('Optimizer API key not found');

    final systemPrompt = '你是图像生成 prompt 工程师。根据下面的话题内容和用户的画图需求，'
        '输出一段精炼的英文 image prompt（≤200 词），描述具体的视觉元素、风格、'
        '构图、光线、色调、媒介。不要在 prompt 中要求嵌入文字。'
        '直接输出 prompt 文本，不要任何解释或前缀。';

    final userMsg = AiChatMessage(
      id: 'optimizer-input',
      role: ChatRole.user,
      content: '话题上下文：\n$contextSummary\n\n用户画图需求：$userPrompt',
      createdAt: DateTime.now(),
    );

    final buf = StringBuffer();
    await chatService
        .sendChatStream(
          provider: optimizer.provider,
          model: optimizer.model.id,
          apiKey: apiKey,
          messages: [userMsg],
          systemPrompt: systemPrompt,
        )
        .timeout(const Duration(seconds: 15))
        .forEach((chunk) {
      if (chunk is TextDelta) buf.write(chunk.text);
    });
    return buf.toString().trim();
  }

  /// 把 messages 列表里**最后一条** user 消息的 content 替换成新值
  List<AiChatMessage> _replaceLastUserContent(
    List<AiChatMessage> messages,
    String newContent,
  ) {
    final result = [...messages];
    for (var i = result.length - 1; i >= 0; i--) {
      if (result[i].role == ChatRole.user) {
        result[i] = result[i].copyWith(content: newContent);
        break;
      }
    }
    return result;
  }

  /// 给图像生成路径用的上下文摘要：含标题 + 楼层正文，
  /// 由 AiChatService 拼到 image prompt 之前，让图像反映话题内容。
  String _buildImageContextSummary(
    TopicContext topicContext,
    ContextScope contextScope,
  ) {
    final body = _buildContextText(topicContext, contextScope);
    if (body.isEmpty) return '【话题】${topicContext.title}';
    return '【话题】${topicContext.title}\n\n$body';
  }

  /// 根据 ContextScope 构建上下文文本
  String _buildContextText(
    TopicContext topicContext,
    ContextScope contextScope,
  ) {
    final posts = topicContext.posts;
    if (posts.isEmpty) return '';

    List<TopicPostContext> selectedPosts;
    switch (contextScope) {
      case ContextScope.firstPostOnly:
        selectedPosts = posts.take(1).toList();
      case ContextScope.first5:
        selectedPosts = posts.take(5).toList();
      case ContextScope.first10:
        selectedPosts = posts.take(10).toList();
      case ContextScope.first20:
        selectedPosts = posts.take(20).toList();
      case ContextScope.all:
        selectedPosts = posts;
    }

    final buffer = StringBuffer();
    for (final post in selectedPosts) {
      buffer.writeln('#${post.postNumber} @${post.username}:');
      buffer.writeln(_stripHtml(post.cooked));
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// 简单的 HTML 转纯文本
  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<p>'), '')
        .replaceAll(RegExp(r'</p>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'&quot;'), '"')
        .replaceAll(RegExp(r'&#39;'), "'")
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// 首次回复完成后自动生成会话标题
  Future<void> _tryGenerateTitle() async {
    final sessionId = state.currentSessionId;
    if (sessionId == null || _isGeneratingTitle) return;

    // 检查是否已有标题
    final sessions = state.sessions;
    final session = sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session?.title != null) return;

    // 只在首次对话完成时生成（用户消息 + AI 回复 = 2条）
    final completedMessages = state.messages
        .where(
            (m) => m.status == MessageStatus.completed && m.content.isNotEmpty)
        .toList();
    if (completedMessages.length != 2) return;

    final model = titleModel;
    if (model == null) return;

    _isGeneratingTitle = true;

    try {
      final apiKey = await AiProviderListNotifier.getApiKey(model.provider.id);
      if (apiKey == null || !mounted) return;

      final userMsg =
          completedMessages.firstWhere((m) => m.role == ChatRole.user).content;

      final titleStream = chatService.sendChatStream(
        provider: model.provider,
        model: model.model.id,
        apiKey: apiKey,
        messages: [
          AiChatMessage(
            id: 'title-prompt',
            role: ChatRole.user,
            content: userMsg,
            createdAt: DateTime.now(),
          ),
        ],
        systemPrompt: AiL10n.current.titleGenerationPrompt,
      );

      final buffer = StringBuffer();
      await for (final chunk in titleStream) {
        if (chunk is TextDelta) {
          buffer.write(chunk.text);
        }
        // 标题生成忽略 thinking / usage
      }

      final title = buffer.toString().trim();
      if (title.isNotEmpty && mounted) {
        await storageService.updateSessionTitle(topicId, sessionId, title);
        state =
            state.copyWith(sessions: storageService.getTopicSessions(topicId));
      }
    } catch (_) {
      // 标题生成失败不影响正常使用
    } finally {
      _isGeneratingTitle = false;
    }
  }

  /// 删除 partial 帧对应的本地文件（被新版 partial 覆盖时调用，节省磁盘）
  void _deletePartialFile(AiChatAttachment att) {
    final path = att.localPath;
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 删失败无所谓，最多占点磁盘
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _requestClient?.close();
    super.dispose();
  }
}

/// 工具：去除 partialImageIndex 字段（onDone 时把残留 partial 升级为终态）
extension _AttachmentPartialUpgrade on AiChatAttachment {
  AiChatAttachment withoutPartialIndex() {
    if (partialImageIndex == null) return this;
    return AiChatAttachment(
      mimeType: mimeType,
      base64Data: base64Data,
      localPath: localPath,
      remoteUrl: remoteUrl,
      // partialImageIndex omitted → 升级为终态
    );
  }
}
