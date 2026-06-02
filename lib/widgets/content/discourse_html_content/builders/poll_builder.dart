import 'package:flutter/material.dart';
import '../../../../models/topic.dart';
import 'package:dio/dio.dart';
import '../../../../services/app_error_handler.dart';
import '../../../../services/discourse/discourse_service.dart';
import '../../../../l10n/s.dart';

/// 构建投票块
Widget buildPoll({
  required BuildContext context,
  required ThemeData theme,
  required dynamic element,
  required Post post,
}) {
  final pollTitle = _extractPollTitle(element);
  final pollName = element.attributes['data-poll-name'] ?? 'poll';
  final poll = post.polls?.firstWhere((p) => p.name == pollName, orElse: () => Poll(id: 0, name: pollName, type: 'regular', status: 'open', results: 'always', options: [], voters: 0));

  if (poll == null || poll.options.isEmpty) {
    return const SizedBox.shrink();
  }

  final userVotes = post.pollsVotes?[pollName] ?? [];

  return _PollWidget(
    poll: poll,
    title: pollTitle,
    post: post,
    userVotes: userVotes,
    onPollUpdated: (updatedPoll, updatedVotes) {
      final pollIndex = post.polls?.indexWhere((p) => p.name == pollName) ?? -1;
      if (pollIndex >= 0 && post.polls != null) {
        post.polls![pollIndex] = updatedPoll;
      }
      if (post.pollsVotes != null) {
        post.pollsVotes![pollName] = updatedVotes;
      }
    },
  );
}

String? _extractPollTitle(dynamic element) {
  final attributeTitle = element.attributes['data-poll-question'] ?? element.attributes['data-poll-title'];
  if (attributeTitle is String && attributeTitle.trim().isNotEmpty) {
    return attributeTitle.trim();
  }

  final pollTitleElements = element.getElementsByClassName('poll-title');
  if (pollTitleElements.isNotEmpty) {
    final text = pollTitleElements.first.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }

  final pollQuestionElements = element.getElementsByClassName('poll-question');
  if (pollQuestionElements.isNotEmpty) {
    final text = pollQuestionElements.first.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
  }

  return null;
}

class _PollWidget extends StatefulWidget {
  final Poll poll;
  final String? title;
  final Post post;
  final List<String> userVotes;
  final Function(Poll, List<String>) onPollUpdated;

  const _PollWidget({
    required this.poll,
    this.title,
    required this.post,
    required this.userVotes,
    required this.onPollUpdated,
  });

  @override
  State<_PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<_PollWidget> {
  late Poll _poll;
  late List<String> _userVotes;
  late bool _showResults;
  bool _isVoting = false;
  bool _showPercentage = true; // true: 百分比, false: 计数

  @override
  void initState() {
    super.initState();
    _poll = widget.poll;
    _userVotes = List.from(widget.userVotes);
    _showResults = _shouldShowResults();
  }

  bool _shouldShowResults() {
    final hasVoted = _userVotes.isNotEmpty;
    final isClosed = _poll.status == 'closed';

    // 如果是 on_close 且未关闭，不显示结果
    if (_poll.results == 'on_close' && !isClosed) {
      return false;
    }

    // 如果是 staff_only，不显示结果（需要管理员权限）
    if (_poll.results == 'staff_only') {
      return false;
    }

    // 满足以下任一条件就显示结果
    return hasVoted || isClosed;
  }

  bool get _isMultiple => _poll.type == 'multiple';

  Future<void> _vote(String optionId) async {
    if (_poll.status == 'closed' || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      // 多选：切换选项
      List<String> votesToSubmit;
      if (_isMultiple) {
        if (_userVotes.contains(optionId)) {
          _userVotes.remove(optionId);
        } else {
          _userVotes.add(optionId);
        }
        votesToSubmit = List.from(_userVotes);
        setState(() {});
        return; // 多选不立即提交
      } else {
        // 单选：直接提交
        votesToSubmit = [optionId];
      }

      final result = await DiscourseService().votePoll(
        postId: widget.post.id,
        pollName: _poll.name,
        options: votesToSubmit,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _userVotes = votesToSubmit;
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, votesToSubmit);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _submitMultipleVote() async {
    if (_userVotes.isEmpty || _isVoting) return;

    setState(() => _isVoting = true);

    try {
      final result = await DiscourseService().votePoll(
        postId: widget.post.id,
        pollName: _poll.name,
        options: _userVotes,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, _userVotes);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  Future<void> _removeVote() async {
    if (_isVoting) return;

    setState(() => _isVoting = true);

    try {
      final result = await DiscourseService().removeVote(
        postId: widget.post.id,
        pollName: _poll.name,
      );

      if (result != null && mounted) {
        setState(() {
          _poll = result;
          _userVotes = [];
          _showResults = _shouldShowResults();
        });
        widget.onPollUpdated(result, []);
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isClosed = _poll.status == 'closed';
    final hasVoted = _userVotes.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.title != null && widget.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(
                widget.title!,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (_showResults)
            _buildResults(theme)
          else
            _buildOptions(theme),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isClosed ? Icons.lock_outline : Icons.poll_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  S.current.poll_voters(_poll.voters),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isClosed) ...[
                  const SizedBox(width: 8),
                  Text(
                    '• ${S.current.poll_closed}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                // 多选投票按钮
                if (_isMultiple && !_showResults && _userVotes.isNotEmpty)
                  TextButton(
                    onPressed: _submitMultipleVote,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ),
                    child: Text(
                      S.current.poll_vote,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                // 撤销投票按钮
                if (!isClosed && hasVoted && !_showResults && !_isMultiple)
                  TextButton(
                    onPressed: _removeVote,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      S.current.poll_undo,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                // 切换显示模式按钮
                if (_showResults && _poll.voters > 0)
                  TextButton(
                    onPressed: () => setState(() => _showPercentage = !_showPercentage),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      _showPercentage ? S.current.poll_count : S.current.poll_percentage,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                // 投票/查看结果切换按钮 - 当 results 为 always 或者用户已投票时显示
                if (!isClosed && (hasVoted || _poll.results == 'always'))
                  TextButton(
                    onPressed: () => setState(() => _showResults = !_showResults),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      _showResults ? S.current.poll_vote : S.current.poll_viewResults,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptions(ThemeData theme) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _poll.options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = _poll.options[index];
        final isUserVoted = _userVotes.contains(option.id);

        return InkWell(
          onTap: _isVoting ? null : () => _vote(option.id),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isUserVoted
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  : theme.colorScheme.surface,
              border: Border.all(
                color: isUserVoted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withValues(alpha: 0.2),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                // 单选/多选图标
                Icon(
                  _isMultiple
                      ? (isUserVoted ? Icons.check_box : Icons.check_box_outline_blank)
                      : (isUserVoted ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  size: 20,
                  color: isUserVoted ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isUserVoted ? FontWeight.w500 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildResults(ThemeData theme) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _poll.options.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final option = _poll.options[index];
        final percentage = _poll.voters > 0 ? (option.votes / _poll.voters * 100) : 0.0;
        final isUserVoted = _userVotes.contains(option.id);

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isUserVoted
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                : theme.colorScheme.surface,
            border: Border.all(
              color: isUserVoted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (isUserVoted) ...[
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            option.html.replaceAll(RegExp(r'<[^>]*>'), ''),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isUserVoted ? FontWeight.w500 : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _showPercentage
                        ? '${percentage.toStringAsFixed(0)}%'
                        : '${option.votes}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: percentage / 100,
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                    isUserVoted ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
