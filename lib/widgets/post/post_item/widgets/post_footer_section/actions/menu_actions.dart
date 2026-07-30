part of '../post_footer_section.dart';

extension _PostFooterMenuActions on _PostFooterSectionState {
  Future<void> _sharePost() async {
    final url =
        '${AppConstants.baseUrl}/t/${widget.topicId}/${widget.post.postNumber}';
    await SharePlus.instance.share(ShareParams(text: url));
  }

  void _showFlagDialog(BuildContext context) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false, // 举报表单(card):禁止下滑误关
      builder: (context) => PostFlagSheet(
        postId: widget.post.id,
        postUsername: widget.post.username,
        service: _service,
        onSuccess: () => ToastService.showSuccess(S.current.post_flagSubmitted),
      ),
    );
  }

  void _showDeleteConfirmDialog(BuildContext context, ThemeData theme) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.post_deleteReplyTitle),
        content: Text(context.l10n.post_deleteReplyConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deletePost();
            },
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            child: Text(context.l10n.common_delete),
          ),
        ],
      ),
    );
  }

  void _showMoreMenu(BuildContext context, ThemeData theme) {
    final isGuest = ref.read(currentUserProvider).value == null;

    showAppBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => AppSheetScaffold(
        showCloseButton: false,
        maxHeightFactor: 0.7,
        contentPadding: EdgeInsets.zero,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onShowPostDetail != null)
                ListTile(
                  leading: Icon(
                    widget.postDetailLabel != null
                        ? Symbols.open_in_new_rounded
                        : Symbols.article_rounded,
                    color: theme.colorScheme.onSurface,
                  ),
                  title: Text(
                    widget.postDetailLabel ?? context.l10n.post_detail,
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onShowPostDetail!();
                  },
                ),
              if (widget.onReply != null)
                ListTile(
                  leading: Icon(
                    Symbols.reply_rounded,
                    color: theme.colorScheme.onSurface,
                  ),
                  title: Text(context.l10n.common_reply),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onReply!();
                  },
                ),
              if (widget.post.canEdit && widget.onEdit != null)
                ListTile(
                  leading: Icon(
                    Symbols.edit_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(
                    context.l10n.common_edit,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onEdit!();
                  },
                ),
              // 菜单点击后才构建，用 read 避免给楼层常驻树增加监听。
              if (ref.read(preferencesProvider).aiTranslationEnabled &&
                  ref.read(aiTranslationSelectedModelProvider) != null)
                ListTile(
                  leading: Icon(
                    Symbols.translate_rounded,
                    color: theme.colorScheme.onSurface,
                  ),
                  title: Text(context.l10n.ai_translationMenuLabel),
                  onTap: () {
                    Navigator.pop(ctx);
                    showAiTranslationSheet(
                      context,
                      cookedHtml: widget.post.cooked,
                    );
                  },
                ),
              ListTile(
                leading: Icon(
                  Symbols.share_rounded,
                  color: theme.colorScheme.onSurface,
                ),
                title: Text(context.l10n.common_shareLink),
                onTap: () {
                  Navigator.pop(ctx);
                  _sharePost();
                },
              ),
              if (widget.onShareAsImage != null)
                ListTile(
                  leading: Icon(
                    Symbols.image_rounded,
                    color: theme.colorScheme.onSurface,
                  ),
                  title: Text(context.l10n.post_generateShareImage),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onShareAsImage!();
                  },
                ),
              if (!isGuest)
                Builder(
                  builder: (context) {
                    final currentUser = ref.read(currentUserProvider).value;
                    final isOwnPost =
                        currentUser != null &&
                        currentUser.username == widget.post.username;
                    if (isOwnPost || widget.post.userId == null) {
                      return const SizedBox.shrink();
                    }
                    return ListTile(
                      leading: Icon(
                        Symbols.volunteer_activism_rounded,
                        color: theme.colorScheme.onSurface,
                      ),
                      title: Text(context.l10n.post_tipLdc),
                      onTap: () async {
                        Navigator.pop(ctx);
                        try {
                          final credentials = await ref.read(
                            ldcRewardCredentialsProvider.future,
                          );
                          if (!mounted) return;
                          if (credentials == null) {
                            ToastService.showError(
                              S.current.toast_rewardNotConfigured,
                            );
                            return;
                          }
                        } catch (error) {
                          debugPrint('[LdcReward] 读取凭证失败: $error');
                          ToastService.showError(
                            S.current.common_operationFailed(error.toString()),
                          );
                          return;
                        }
                        if (!mounted) return;
                        showLdcRewardSheet(
                          this.context,
                          RewardTargetInfo(
                            userId: widget.post.userId!,
                            username: widget.post.username,
                            name: widget.post.name,
                            avatarUrl: widget.post.getAvatarUrl(),
                            topicId: widget.topicId,
                            postId: widget.post.id,
                          ),
                        );
                      },
                    );
                  },
                ),
              if (!isGuest &&
                  (widget.post.canAcceptAnswer ||
                      widget.post.canUnacceptAnswer))
                ListTile(
                  leading: Icon(
                    _isAcceptedAnswer
                        ? Symbols.check_box_rounded
                        : Symbols.check_box_outline_blank_rounded,
                    color: _isAcceptedAnswer
                        ? Colors.green
                        : theme.colorScheme.onSurface,
                  ),
                  title: Text(
                    _isAcceptedAnswer
                        ? context.l10n.post_unacceptSolution
                        : context.l10n.post_acceptSolution,
                    style: TextStyle(
                      color: _isAcceptedAnswer
                          ? Colors.green
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  onTap: _isTogglingAnswer
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _toggleSolution();
                        },
                ),
              if (!isGuest)
                ListTile(
                  leading: Icon(
                    Symbols.bookmark_rounded,
                    fill: _isBookmarked ? 1 : 0,
                    color: _isBookmarked
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                  title: Text(
                    _isBookmarked
                        ? context.l10n.bookmark_editBookmark
                        : context.l10n.common_addBookmark,
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_isBookmarked) {
                      _editBookmark();
                    } else {
                      _addBookmark();
                    }
                  },
                ),
              if (widget.canAssignPost && widget.onAssignPost != null)
                ListTile(
                  leading: Icon(
                    Icons.assignment_ind_outlined,
                    color: theme.colorScheme.onSurface,
                  ),
                  title: const Text('指定帖子'),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onAssignPost!();
                  },
                ),
              if (!isGuest)
                ListTile(
                  leading: Icon(
                    Symbols.flag_rounded,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    context.l10n.common_report,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showFlagDialog(context);
                  },
                ),
              if (!isGuest && widget.post.canRecover)
                ListTile(
                  leading: Icon(
                    Symbols.restore_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  title: Text(
                    context.l10n.common_restore,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  onTap: _isDeleting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _recoverPost();
                        },
                ),
              if (!isGuest && widget.post.canDelete && !widget.post.isDeleted)
                ListTile(
                  leading: Icon(
                    Symbols.delete_rounded,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(
                    context.l10n.common_delete,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: _isDeleting
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _showDeleteConfirmDialog(context, theme);
                        },
                ),
              // 仅 debug build:复制 cooked HTML(给渲染引擎调试用)
              if (kDebugMode) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: Icon(
                    Symbols.bug_report_rounded,
                    color: theme.colorScheme.tertiary,
                  ),
                  title: Text(
                    'Copy cooked HTML',
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
                  subtitle: Text(
                    'debug: ${widget.post.cooked.length} chars',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(
                      ClipboardData(text: widget.post.cooked),
                    );
                    ToastService.showSuccess(
                      'cooked HTML 已复制 (${widget.post.cooked.length} chars)',
                    );
                  },
                ),
                // 复制签名(user_signature:advanced 模式为 HTML,否则为图片 URL)
                if (widget.post.effectiveSignature != null)
                  ListTile(
                    leading: Icon(
                      Symbols.bug_report_rounded,
                      color: theme.colorScheme.tertiary,
                    ),
                    title: Text(
                      'Copy signature',
                      style: TextStyle(color: theme.colorScheme.tertiary),
                    ),
                    subtitle: Text(
                      'debug: ${widget.post.effectiveSignature!.length} chars',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final signature = widget.post.effectiveSignature!;
                      await Clipboard.setData(ClipboardData(text: signature));
                      ToastService.showSuccess(
                        '签名已复制 (${signature.length} chars)',
                      );
                    },
                  ),
              ],
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                title: Text(
                  context.l10n.common_cancel,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
