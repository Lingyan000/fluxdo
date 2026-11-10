import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/discourse_providers.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/toast_service.dart';

/// "俺也一样" (discourse-solved 的 shared_issue) 按钮
///
/// 显示规则：
/// - `sharedIssueVisible == false` 不渲染
/// - `canCreateSharedIssue == false`（自己的帖子等）禁用并显示 author tooltip
/// - 点击同接口 toggle，服务端会切换状态
class SharedIssueButton extends ConsumerStatefulWidget {
  final TopicDetail topic;
  final void Function(int count, bool userMarked)? onChanged;

  const SharedIssueButton({super.key, required this.topic, this.onChanged});

  @override
  ConsumerState<SharedIssueButton> createState() => _SharedIssueButtonState();
}

class _SharedIssueButtonState extends ConsumerState<SharedIssueButton> {
  bool _isLoading = false;
  bool _userMarked = false;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _userMarked = widget.topic.userCreatedSharedIssue;
    _count = widget.topic.sharedIssueCount;
  }

  @override
  void didUpdateWidget(SharedIssueButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic.id != widget.topic.id ||
        oldWidget.topic.userCreatedSharedIssue !=
            widget.topic.userCreatedSharedIssue ||
        oldWidget.topic.sharedIssueCount != widget.topic.sharedIssueCount) {
      _userMarked = widget.topic.userCreatedSharedIssue;
      _count = widget.topic.sharedIssueCount;
    }
  }

  Future<void> _handleTap() async {
    if (_isLoading) return;

    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      ToastService.showInfo(S.current.vote_pleaseLogin);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await DiscourseService().toggleSharedIssue(
        widget.topic.id,
      );
      if (!mounted) return;
      setState(() {
        _count = response.count;
        _userMarked = response.userCreatedSharedIssue;
        _isLoading = false;
      });
      widget.onChanged?.call(response.count, response.userCreatedSharedIssue);
      ToastService.showSuccess(
        response.userCreatedSharedIssue
            ? S.current.sharedIssue_marked
            : S.current.sharedIssue_unmarked,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (e.response?.statusCode == 429) {
        ToastService.showInfo(S.current.sharedIssue_rateLimited);
      }
      // 其他错误已由 ErrorInterceptor 统一处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.topic.sharedIssueVisible) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    // canCreateSharedIssue 为 false 时多半是 OP 自己；此时只展示，不可点
    final bool disabled = !widget.topic.canCreateSharedIssue;
    final String tooltip = disabled
        ? S.current.sharedIssue_authorTitle
        : S.current.sharedIssue_title;

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: (disabled || _isLoading) ? null : _handleTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(24),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: ShapeDecoration(
            color: _userMarked
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHigh,
            shadows: _userMarked
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(24),
              side: BorderSide(
                color: _userMarked
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _userMarked
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                    ),
                  ),
                )
              else
                Icon(
                  Symbols.front_hand_rounded,
                  fill: _userMarked ? 1 : 0,
                  size: 18,
                  color: _userMarked
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.primary,
                ),
              const SizedBox(width: 6),
              Text(
                S.current.sharedIssue_label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: _userMarked
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              if (_count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: ShapeDecoration(
                    color: _userMarked
                        ? theme.colorScheme.onPrimary.withValues(alpha: 0.2)
                        : theme.colorScheme.primary.withValues(alpha: 0.1),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(10),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$_count',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: _userMarked
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Opacity(
      opacity: disabled ? 0.7 : 1.0,
      child: Tooltip(message: tooltip, child: button),
    );
  }
}
