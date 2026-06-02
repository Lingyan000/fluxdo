import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../providers/discourse_providers.dart';
import '../../../../providers/preferences_provider.dart';
import 'package:dio/dio.dart';
import '../../../../services/app_error_handler.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../common/relative_time_text.dart';
import '../../small_action_item.dart';
import 'post_header.dart';
import 'post_reply_history.dart';
import 'post_stamp_painter.dart';

class PostHeaderSection extends ConsumerStatefulWidget {
  final Post post;
  final int topicId;
  final bool isTopicOwner;
  final bool showStamp;
  final EdgeInsetsGeometry padding;
  final void Function(int postNumber)? onJumpToPost;
  /// 禁用回复历史（弹框内使用时，显示用户名文本替代可点击操作）
  final bool disableReplyHistory;
  /// 自定义回复指示点击回调（优先于回复历史加载）
  final void Function(int postNumber)? onReplyIndicatorTap;
  /// 隐藏回复指示的目标帖子号（回复此帖时不显示指示器）
  final int? hideReplyToPostNumber;
  const PostHeaderSection({
    super.key,
    required this.post,
    required this.topicId,
    required this.isTopicOwner,
    required this.showStamp,
    required this.padding,
    required this.onJumpToPost,
    this.disableReplyHistory = false,
    this.onReplyIndicatorTap,
    this.hideReplyToPostNumber,
  });

  @override
  ConsumerState<PostHeaderSection> createState() => _PostHeaderSectionState();
}

class _PostHeaderSectionState extends ConsumerState<PostHeaderSection> {
  final DiscourseService _service = DiscourseService();
  List<Post>? _replyHistory;
  final ValueNotifier<bool> _isLoadingReplyHistoryNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _showReplyHistoryNotifier = ValueNotifier<bool>(false);
  Widget? _cachedAvatarWidget;
  int? _cachedPostId;

  @override
  void dispose() {
    _isLoadingReplyHistoryNotifier.dispose();
    _showReplyHistoryNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cachedAvatarWidget == null || _cachedPostId != widget.post.id) {
      final theme = Theme.of(context);
      _cachedAvatarWidget = PostAvatar(
        key: ValueKey('avatar-${widget.post.id}'),
        post: widget.post,
        theme: theme,
      );
      _cachedPostId = widget.post.id;
    }
  }

  Future<void> _toggleReplyHistory() async {
    if (_showReplyHistoryNotifier.value) {
      _showReplyHistoryNotifier.value = false;
      return;
    }

    if (_replyHistory != null) {
      _showReplyHistoryNotifier.value = true;
      return;
    }

    if (_isLoadingReplyHistoryNotifier.value) return;

    _isLoadingReplyHistoryNotifier.value = true;
    try {
      final history = await _service.getPostReplyHistory(widget.post.id);
      if (!mounted) return;
      _replyHistory = history;
      _isLoadingReplyHistoryNotifier.value = false;
      _showReplyHistoryNotifier.value = true;
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
      if (mounted) {
        _isLoadingReplyHistoryNotifier.value = false;
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        _isLoadingReplyHistoryNotifier.value = false;
      }
    }
  }

  Widget _buildCompactBadge(
    BuildContext context,
    String text,
    Color backgroundColor,
    Color textColor,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final post = widget.post;
    final currentUser = ref.read(currentUserProvider).value;
    final isOwnPost = currentUser != null && currentUser.username == post.username;
    final isWhisper = post.postType == PostTypes.whisper;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (widget.showStamp || post.canAcceptAnswer)
          Positioned(
            right: 20,
            top: 10,
            child: IgnorePointer(
              child: Opacity(
                opacity: widget.showStamp ? 0.12 : 0.05,
                child: Transform.rotate(
                  angle: -0.15,
                  child: CustomPaint(
                    painter: PostStampPainter(
                      color: widget.showStamp ? Colors.green : theme.colorScheme.outline,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.showStamp ? Icons.verified : Icons.help_outline,
                            color: widget.showStamp ? Colors.green : theme.colorScheme.outline,
                            size: 28,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.showStamp ? context.l10n.post_solved : context.l10n.post_unsolved,
                            style: TextStyle(
                              color: widget.showStamp ? Colors.green : theme.colorScheme.outline,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              fontFamily: theme.textTheme.titleLarge?.fontFamily,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: widget.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PostHeader(
                post: post,
                topicId: widget.topicId,
                isTopicOwner: widget.isTopicOwner,
                isOwnPost: isOwnPost,
                isWhisper: isWhisper,
                cachedAvatarWidget: _cachedAvatarWidget!,
                isLoadingReplyHistoryNotifier: widget.disableReplyHistory ? null : _isLoadingReplyHistoryNotifier,
                onToggleReplyHistory: widget.disableReplyHistory ? null : _toggleReplyHistory,
                onReplyIndicatorTap: widget.onReplyIndicatorTap != null && widget.post.replyToPostNumber > 0
                    ? () => widget.onReplyIndicatorTap!(widget.post.replyToPostNumber)
                    : null,
                hideReplyIndicator: widget.hideReplyToPostNumber != null &&
                    widget.post.replyToPostNumber == widget.hideReplyToPostNumber,
                buildCompactBadge: _buildCompactBadge,
                timeAndFloorWidget: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        RelativeTimeText(
                          dateTime: post.createdAt,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                            fontSize: 11,
                          ),
                        ),
                        Positioned(
                          right: -6,
                          top: -2,
                          child: Consumer(
                            builder: (context, ref, _) {
                              final sessionState = ref.watch(topicSessionProvider(widget.topicId));
                              final isNew = !widget.post.read;
                              final isReadInSession = sessionState.readPostNumbers.contains(
                                widget.post.postNumber,
                              );
                              final show = isNew && !isReadInSession;

                              return AnimatedOpacity(
                                opacity: show ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 500),
                                curve: Curves.easeOut,
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.colorScheme.surface,
                                      width: 1,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '#${post.postNumber}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _showReplyHistoryNotifier,
                builder: (context, showReplyHistory, _) {
                  if (!showReplyHistory) return const SizedBox.shrink();
                  return PostReplyHistory(
                    replyHistory: _replyHistory,
                    showReplyHistoryNotifier: _showReplyHistoryNotifier,
                    onJumpToPost: widget.onJumpToPost,
                    contentFontScale: ref.watch(preferencesProvider).contentFontScale,
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
