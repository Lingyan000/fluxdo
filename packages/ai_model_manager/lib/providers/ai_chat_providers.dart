import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../models/ai_provider.dart';
import '../models/ai_chat_message.dart';
import '../services/ai_chat_service.dart';
import 'ai_provider_providers.dart';

const _lastUsedAiAssistantModelKey = 'ai_assistant_last_model';

({AiProvider provider, AiModel model})? _findAiModelByKey(
  List<({AiProvider provider, AiModel model})> all,
  String? key,
) {
  if (key == null || key.isEmpty) return null;

  final parts = key.split(':');
  if (parts.length != 2) return null;

  for (final item in all) {
    if (item.provider.id == parts[0] && item.model.id == parts[1]) {
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

/// 默认/首选的 AI 模型
final defaultAiModelProvider =
    Provider<({AiProvider provider, AiModel model})?>(
  (ref) {
    final all = ref.watch(allAvailableAiModelsProvider);
    if (all.isEmpty) return null;

    final defaultKey = ref.watch(defaultAiModelKeyProvider);
    return _findAiModelByKey(all, defaultKey) ?? all.first;
  },
);

/// AI 助手上次使用的模型 key（providerId:modelId）
final lastUsedAiAssistantModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_lastUsedAiAssistantModelKey);
});

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
Future<void> setLastUsedAiAssistantModel(
  WidgetRef ref,
  String providerId,
  String modelId,
) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  final key = '$providerId:$modelId';
  await prefs.setString(_lastUsedAiAssistantModelKey, key);
  ref.read(lastUsedAiAssistantModelKeyProvider.notifier).state = key;
}

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
final aiChatServiceProvider = Provider((_) => AiChatService());

/// 话题 AI 上下文范围（独立管理，避免切换时影响消息列表滚动）
final topicAiContextScopeProvider = StateProvider.autoDispose
    .family<ContextScope, int>((ref, topicId) => ContextScope.first5);

/// 话题 AI 聊天状态
class TopicAiChatState {
  final List<AiChatMessage> messages;
  final bool isGenerating;

  const TopicAiChatState({
    this.messages = const [],
    this.isGenerating = false,
  });

  TopicAiChatState copyWith({
    List<AiChatMessage>? messages,
    bool? isGenerating,
  }) {
    return TopicAiChatState(
      messages: messages ?? this.messages,
      isGenerating: isGenerating ?? this.isGenerating,
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
    return TopicAiChatNotifier(chatService: chatService);
  },
);

class TopicAiChatNotifier extends StateNotifier<TopicAiChatState> {
  static const _uuid = Uuid();

  final AiChatService chatService;

  StreamSubscription<String>? _streamSubscription;
  bool _cancelled = false;

  /// 缓存的上下文帖子（通过 fetchContextPosts 加载）
  List<TopicPostContext>? _cachedContextPosts;
  String? _cachedTitle;

  TopicAiChatNotifier({
    required this.chatService,
  }) : super(const TopicAiChatState());

  /// 设置上下文帖子缓存（由外部在加载完成后调用）
  void setContextPosts(String title, List<TopicPostContext> posts) {
    _cachedTitle = title;
    _cachedContextPosts = posts;
  }

  /// 发送消息
  Future<void> sendMessage(
    String content,
    ContextScope contextScope, {
    required ({AiProvider provider, AiModel model}) selectedModel,
  }) async {
    if (content.trim().isEmpty) return;

    _cancelled = false;

    // 添加用户消息
    final userMessage = AiChatMessage(
      id: _uuid.v4(),
      role: ChatRole.user,
      content: content.trim(),
      createdAt: DateTime.now(),
    );

    // 添加 AI 占位消息
    final assistantMessage = AiChatMessage(
      id: _uuid.v4(),
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.now(),
      status: MessageStatus.streaming,
    );

    state = state.copyWith(
      messages: [...state.messages, userMessage, assistantMessage],
      isGenerating: true,
    );

    try {
      // 获取 API Key
      final apiKey =
          await AiProviderListNotifier.getApiKey(selectedModel.provider.id);
      if (apiKey == null || !mounted) return;

      // 构建上下文
      final topicContext = _cachedContextPosts != null && _cachedTitle != null
          ? TopicContext(title: _cachedTitle!, posts: _cachedContextPosts!)
          : null;

      // 构建消息列表
      final chatMessages = _buildChatMessages(topicContext, contextScope);

      // 发起流式请求
      final stream = chatService.sendChatStream(
        provider: selectedModel.provider,
        model: selectedModel.model.id,
        apiKey: apiKey,
        messages: chatMessages,
        systemPrompt: _buildSystemPrompt(topicContext),
      );

      final buffer = StringBuffer();

      _streamSubscription = stream.listen(
        (token) {
          if (_cancelled || !mounted) return;
          buffer.write(token);
          _updateAssistantMessage(
            assistantMessage.id,
            buffer.toString(),
            MessageStatus.streaming,
          );
        },
        onDone: () {
          if (!mounted) return;
          _updateAssistantMessage(
            assistantMessage.id,
            buffer.toString(),
            MessageStatus.completed,
          );
          state = state.copyWith(isGenerating: false);
        },
        onError: (error) {
          if (!mounted) return;
          _updateAssistantMessage(
            assistantMessage.id,
            buffer.toString(),
            MessageStatus.error,
            errorMessage: error.toString(),
          );
          state = state.copyWith(isGenerating: false);
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      _updateAssistantMessage(
        assistantMessage.id,
        '',
        MessageStatus.error,
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

  /// 清空消息
  void clearMessages() {
    stopGeneration();
    state = state.copyWith(messages: []);
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
    String messageId,
    String content,
    MessageStatus status, {
    String? errorMessage,
  }) {
    if (!mounted) return;
    final messages = state.messages.map((m) {
      if (m.id == messageId) {
        return m.copyWith(
          content: content,
          status: status,
          errorMessage: errorMessage,
        );
      }
      return m;
    }).toList();
    state = state.copyWith(messages: messages);
  }

  /// 构建系统提示
  String _buildSystemPrompt(TopicContext? topicContext) {
    final buffer = StringBuffer();
    buffer.writeln('你是一个有帮助的 AI 助手，正在帮助用户理解和讨论一个论坛话题。');
    if (topicContext != null) {
      buffer.writeln('话题标题：${topicContext.title}');
      buffer.writeln('用户可能会就话题内容向你提问，请基于提供的上下文回答。');
    }
    buffer.writeln('请用 Markdown 格式回复。');
    return buffer.toString();
  }

  /// 构建聊天消息列表（包含上下文）
  List<Map<String, String>> _buildChatMessages(
    TopicContext? topicContext,
    ContextScope contextScope,
  ) {
    final result = <Map<String, String>>[];

    // 注入上下文
    if (topicContext != null) {
      final contextText = _buildContextText(topicContext, contextScope);
      if (contextText.isNotEmpty) {
        result.add({'role': 'user', 'content': '以下是话题内容：\n$contextText'});
        result.add({
          'role': 'assistant',
          'content': '好的，我已经阅读了话题内容。请问你有什么问题？',
        });
      }
    }

    // 添加历史消息（排除 system 和 streaming/error 状态的空消息）
    for (final msg in state.messages) {
      if (msg.role == ChatRole.system) continue;
      if (msg.content.isEmpty && msg.role == ChatRole.assistant) continue;
      result.add({
        'role': msg.role == ChatRole.user ? 'user' : 'assistant',
        'content': msg.content,
      });
    }

    return result;
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

  @override
  void dispose() {
    _streamSubscription?.cancel();
    super.dispose();
  }
}
