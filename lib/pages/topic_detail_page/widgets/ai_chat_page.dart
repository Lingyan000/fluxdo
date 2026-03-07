import 'dart:async';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/topic.dart';
import '../../../services/discourse/discourse_service.dart';
import 'ai_chat_input.dart';
import 'ai_chat_message_item.dart';
import 'ai_context_selector.dart';

/// AI 聊天全屏页面
class AiChatPage extends ConsumerStatefulWidget {
  final int topicId;
  final TopicDetail? detail;

  /// 状态栏高度（从父 context 传入，modal 内部会清零 padding.top）
  final double topPadding;

  const AiChatPage({
    super.key,
    required this.topicId,
    required this.topPadding,
    this.detail,
  });

  @override
  ConsumerState<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends ConsumerState<AiChatPage> {
  /// 已获取到的上下文帖子（按 postNumber 升序）
  final List<TopicPostContext> _contextPosts = [];

  /// 已获取的帖子 ID 集合（避免重复请求）
  final Set<int> _fetchedPostIds = {};

  /// 是否正在加载上下文
  bool _isLoadingContext = false;

  /// 上一次加载使用的 scope，用于检测变化
  ContextScope? _lastLoadedScope;

  @override
  void didUpdateWidget(AiChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detail != oldWidget.detail && widget.detail != null) {
      _ensureContextPosts();
    }
  }

  /// 确保上下文帖子已加载，根据当前 scope 需要的数量
  Future<void> _ensureContextPosts() async {
    final detail = widget.detail;
    if (detail == null || _isLoadingContext) return;

    final scope = ref.read(topicAiContextScopeProvider(widget.topicId));

    // 计算需要多少条帖子
    final stream = detail.postStream.stream;
    final needed = _postCountForScope(scope, stream.length);
    final neededIds = stream.take(needed).toList();

    // 检查是否已经有足够的帖子
    if (neededIds.every(_fetchedPostIds.contains)) {
      _lastLoadedScope = scope;
      _syncToNotifier(detail.title);
      return;
    }

    // 找出缺失的帖子 ID
    final missingIds = neededIds
        .where((id) => !_fetchedPostIds.contains(id))
        .toList();
    if (missingIds.isEmpty) return;

    setState(() => _isLoadingContext = true);

    try {
      // 优先从已加载的 detail.postStream.posts 中取
      final loadedPosts = detail.postStream.posts;
      final loadedMap = {for (final p in loadedPosts) p.id: p};

      final fromLoaded = <TopicPostContext>[];
      final stillMissing = <int>[];

      for (final id in missingIds) {
        final post = loadedMap[id];
        if (post != null) {
          fromLoaded.add(
            TopicPostContext(
              postNumber: post.postNumber,
              username: post.username,
              cooked: post.cooked,
            ),
          );
          _fetchedPostIds.add(id);
        } else {
          stillMissing.add(id);
        }
      }

      _contextPosts.addAll(fromLoaded);

      // 仍然缺失的通过 API 获取
      if (stillMissing.isNotEmpty) {
        final service = DiscourseService();
        // getPosts 一次最多获取合理数量，分批获取
        for (var i = 0; i < stillMissing.length; i += 20) {
          final batch = stillMissing.sublist(
            i,
            (i + 20).clamp(0, stillMissing.length),
          );
          final postStream = await service.getPosts(widget.topicId, batch);
          for (final post in postStream.posts) {
            if (!_fetchedPostIds.contains(post.id)) {
              _contextPosts.add(
                TopicPostContext(
                  postNumber: post.postNumber,
                  username: post.username,
                  cooked: post.cooked,
                ),
              );
              _fetchedPostIds.add(post.id);
            }
          }
        }
      }

      // 按 postNumber 排序
      _contextPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      _lastLoadedScope = scope;
      if (mounted) {
        _syncToNotifier(detail.title);
      }
    } catch (_) {
      // 加载失败仍允许聊天
    } finally {
      if (mounted) {
        setState(() => _isLoadingContext = false);
      }
    }
  }

  /// 当 scope 变更时检查是否需要加载更多帖子
  void _onScopeChanged(ContextScope newScope) {
    ref.read(topicAiContextScopeProvider(widget.topicId).notifier).state =
        newScope;

    final detail = widget.detail;
    if (detail == null) return;

    final stream = detail.postStream.stream;
    final needed = _postCountForScope(newScope, stream.length);
    final neededIds = stream.take(needed).toSet();

    // 检查是否缺少帖子
    if (!neededIds.every(_fetchedPostIds.contains)) {
      _ensureContextPosts();
    }
  }

  /// 根据 scope 返回需要的帖子数量
  int _postCountForScope(ContextScope scope, int total) {
    return switch (scope) {
      ContextScope.firstPostOnly => 1,
      ContextScope.first5 => 5.clamp(0, total),
      ContextScope.first10 => 10.clamp(0, total),
      ContextScope.first20 => 20.clamp(0, total),
      ContextScope.all => total,
    };
  }

  /// 同步上下文帖子到 Notifier
  void _syncToNotifier(String title) {
    ref
        .read(topicAiChatProvider(widget.topicId).notifier)
        .setContextPosts(title, _contextPosts);
  }

  ({AiProvider provider, AiModel model})? _currentModel() {
    final selected = ref.read(topicSelectedAiModelProvider(widget.topicId));
    final lastUsed = ref.read(lastUsedAiAssistantModelProvider);
    final defaultModel = ref.read(defaultAiModelProvider);
    return selected ?? lastUsed ?? defaultModel;
  }

  void _rememberModel(({AiProvider provider, AiModel model}) model) {
    ref.read(topicSelectedAiModelProvider(widget.topicId).notifier).state =
        model;
    unawaited(
      setLastUsedAiAssistantModel(ref, model.provider.id, model.model.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chatState = ref.watch(topicAiChatProvider(widget.topicId));
    final chatNotifier = ref.read(topicAiChatProvider(widget.topicId).notifier);

    // 首次 build 且有 detail 时加载上下文
    if (widget.detail != null && _lastLoadedScope == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureContextPosts();
      });
    }

    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final screenHeight = mediaQuery.size.height;
    // 内容区高度：键盘弹出时收缩，确保不超过屏幕顶部状态栏
    final contentHeight = (screenHeight * 0.9).clamp(
      0.0,
      screenHeight - widget.topPadding - bottomInset,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: contentHeight,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 顶部拖动条
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // 自定义标题栏
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'AI 助手',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Consumer(
                          builder: (context, ref, _) {
                            final scope = ref.watch(
                              topicAiContextScopeProvider(widget.topicId),
                            );
                            return AiContextSelector(
                              currentScope: scope,
                              onChanged: _onScopeChanged,
                            );
                          },
                        ),
                        if (chatState.messages.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '清空聊天',
                            onPressed: () =>
                                _confirmClear(context, chatNotifier),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // 上下文加载提示
              if (_isLoadingContext)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: theme.colorScheme.primary,
                ),

              // 聊天主要内容区
              Expanded(
                child: chatState.messages.isEmpty
                    ? _buildEmptyState(context, theme)
                    : _buildMessageList(context, ref, chatState),
              ),

              // 底部输入区
              AiChatInput(
                isGenerating: chatState.isGenerating,
                onSend: (content) {
                  final scope = ref.read(
                    topicAiContextScopeProvider(widget.topicId),
                  );
                  final model = _currentModel();
                  if (model == null) return;
                  _rememberModel(model);
                  chatNotifier.sendMessage(
                    content,
                    scope,
                    selectedModel: model,
                  );
                },
                onStop: chatNotifier.stopGeneration,
                bottomLeading: Consumer(
                  builder: (context, ref, _) {
                    final allModels = ref.watch(allAvailableAiModelsProvider);
                    final selected = ref.watch(
                      topicSelectedAiModelProvider(widget.topicId),
                    );
                    final lastUsedModel = ref.watch(
                      lastUsedAiAssistantModelProvider,
                    );
                    final defaultModel = ref.watch(defaultAiModelProvider);
                    final current = selected ?? lastUsedModel ?? defaultModel;
                    if (allModels.length <= 1 || current == null) {
                      return const SizedBox.shrink();
                    }
                    return _AiModelSelector(
                      allModels: allModels,
                      current: current,
                      onChanged: _rememberModel,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 常用对话
  static const _quickPrompts = [
    (
      icon: Icons.summarize_outlined,
      label: '总结这个话题',
      prompt: '请简要总结这个话题的主要内容和讨论要点。',
    ),
    (icon: Icons.translate_outlined, label: '翻译主帖', prompt: '请将主帖内容翻译成英文。'),
    (
      icon: Icons.question_answer_outlined,
      label: '列出主要观点',
      prompt: '请列出这个话题中各楼层的主要观点和立场。',
    ),
    (
      icon: Icons.lightbulb_outlined,
      label: '有什么值得关注的',
      prompt: '这个话题中有哪些值得关注的信息或亮点？',
    ),
  ];

  void _sendQuickPrompt(String prompt) {
    final scope = ref.read(topicAiContextScopeProvider(widget.topicId));
    final model = _currentModel();
    if (model == null) return;
    _rememberModel(model);
    ref
        .read(topicAiChatProvider(widget.topicId).notifier)
        .sendMessage(prompt, scope, selectedModel: model);
  }

  Widget _buildEmptyState(BuildContext context, ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '向 AI 助手提问',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'AI 会基于话题内容为你解答',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: _quickPrompts.map((item) {
                return ActionChip(
                  avatar: Icon(item.icon, size: 18),
                  label: Text(item.label),
                  onPressed: () => _sendQuickPrompt(item.prompt),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(
    BuildContext context,
    WidgetRef ref,
    TopicAiChatState chatState,
  ) {
    final messages = chatState.messages;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[messages.length - 1 - index];
        return AiChatMessageItem(
          message: message,
          onRetry: message.status == MessageStatus.error
              ? () {
                  final scope = ref.read(
                    topicAiContextScopeProvider(widget.topicId),
                  );
                  final model = _currentModel();
                  if (model == null) return;
                  _rememberModel(model);
                  ref
                      .read(topicAiChatProvider(widget.topicId).notifier)
                      .retryLastMessage(scope, selectedModel: model);
                }
              : null,
        );
      },
    );
  }

  void _confirmClear(BuildContext context, TopicAiChatNotifier notifier) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空聊天'),
        content: const Text('确定要清空所有聊天记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              notifier.clearMessages();
              Navigator.pop(ctx);
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

/// 模型选择器
class _AiModelSelector extends StatelessWidget {
  final List<({AiProvider provider, AiModel model})> allModels;
  final ({AiProvider provider, AiModel model}) current;
  final ValueChanged<({AiProvider provider, AiModel model})> onChanged;

  const _AiModelSelector({
    required this.allModels,
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopupMenuButton<int>(
      tooltip: '选择模型',
      onSelected: (index) => onChanged(allModels[index]),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 100),
              child: Text(
                current.model.name ?? current.model.id,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.unfold_more,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
      itemBuilder: (context) {
        return allModels.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          final isCurrent =
              item.provider.id == current.provider.id &&
              item.model.id == current.model.id;
          return PopupMenuItem<int>(
            value: index,
            child: Row(
              children: [
                if (isCurrent)
                  Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.model.name ?? item.model.id,
                        style: const TextStyle(fontSize: 14),
                      ),
                      Text(
                        item.provider.name,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList();
      },
    );
  }
}
