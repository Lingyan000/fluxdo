import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/s.dart';
import '../../../models/post_revision.dart';
import '../../../providers/category_provider.dart';
import '../../../providers/core_providers.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/responsive.dart';
import '../../../utils/time_utils.dart';
import '../../common/loading_spinner.dart';
import 'package:common_ui/common_ui.dart';
import '../../common/smart_avatar.dart';
import '../../content/discourse_html_content/discourse_html_content.dart';

/// 帖子编辑历史主视图(放入 modal/page 内)。
///
/// 负责:
/// - 加载并切换 revision(初始为 [initialRevision] 或 latest)
/// - 渲染顶部导航(版本号 + 上一版/下一版,溢出菜单含首版/末版/diff 模式)
/// - 渲染元信息(编辑者 / 时间 / 原因 / 隐藏 badge)
/// - 渲染非 body 变化(标题、分类、标签、wiki 等"旧 → 新")
/// - 渲染正文 diff(根据屏宽自适应默认模式,可手动切换)
/// - 渲染 staff 操作栏(隐藏 / 显示 / 回退 / 永久删除)
///
/// staff 操作成功后,依赖 MessageBus / topic_detail provider 自动刷新对应帖子;
/// 本视图不主动调用 refreshPost,避免与上层 provider 绑定。
class PostRevisionView extends ConsumerStatefulWidget {
  final int postId;
  final int? initialRevision;

  const PostRevisionView({
    super.key,
    required this.postId,
    this.initialRevision,
  });

  @override
  ConsumerState<PostRevisionView> createState() => _PostRevisionViewState();
}

enum _DiffMode { inline, sideBySide, sideBySideMarkdown }

class _PostRevisionViewState extends ConsumerState<PostRevisionView> {
  late final DiscourseService _service = ref.read(discourseServiceProvider);
  PostRevision? _revision;
  bool _loading = true;
  bool _busy = false; // staff 操作进行中
  Object? _error;
  _DiffMode _diffMode = _DiffMode.inline;
  bool _diffModeInitialized = false;

  @override
  void initState() {
    super.initState();
    _load(widget.initialRevision);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次进入根据屏宽确定 diff 默认模式:桌面/平板默认 side-by-side,
    // 移动端默认 inline。仅初始化一次,避免旋转/分屏触发模式切换。
    if (!_diffModeInitialized) {
      _diffModeInitialized = true;
      _diffMode = Responsive.isMobile(context)
          ? _DiffMode.inline
          : _DiffMode.sideBySide;
    }
  }

  Future<void> _load(int? revision) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = revision != null
          ? await _service.getPostRevision(widget.postId, revision)
          : await _service.getLatestPostRevision(widget.postId);
      if (!mounted) return;
      setState(() {
        _revision = result;
        _loading = false;
      });
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _navigateTo(int revision) async {
    if (_busy || _loading) return;
    await _load(revision);
  }

  Future<void> _hideRevision() async {
    final revision = _revision;
    if (revision == null) return;
    final successMessage =
        context.l10n.postRevision_hideSuccess(revision.currentRevision);
    await _runStaffAction(
      () => _service.hidePostRevision(widget.postId, revision.currentRevision),
      successMessage: successMessage,
      reloadAfter: true,
    );
  }

  Future<void> _showRevision() async {
    final revision = _revision;
    if (revision == null) return;
    final successMessage =
        context.l10n.postRevision_showSuccess(revision.currentRevision);
    await _runStaffAction(
      () => _service.showPostRevision(widget.postId, revision.currentRevision),
      successMessage: successMessage,
      reloadAfter: true,
    );
  }

  Future<void> _revertRevision() async {
    final revision = _revision;
    if (revision == null) return;
    final l10n = context.l10n;
    final confirmed = await _confirm(
      title: l10n.postRevision_revertConfirmTitle(revision.currentRevision),
      body: l10n.postRevision_revertConfirmBody,
    );
    if (!confirmed) return;
    final successMessage =
        l10n.postRevision_revertSuccess(revision.currentRevision);
    await _runStaffAction(
      () => _service.revertPostToRevision(widget.postId, revision.currentRevision),
      successMessage: successMessage,
      closeAfter: true,
    );
  }

  Future<void> _permanentlyDelete() async {
    final l10n = context.l10n;
    final confirmed = await _confirm(
      title: l10n.postRevision_permanentlyDeleteTitle,
      body: l10n.postRevision_permanentlyDeleteBody,
      destructive: true,
    );
    if (!confirmed) return;
    final successMessage = l10n.postRevision_deleteAllSuccess;
    await _runStaffAction(
      () => _service.permanentlyDeletePostRevisions(widget.postId),
      successMessage: successMessage,
      closeAfter: true,
    );
  }

  Future<void> _runStaffAction(
    Future<void> Function() action, {
    required String successMessage,
    bool reloadAfter = false,
    bool closeAfter = false,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      ToastService.showSuccess(successMessage);
      if (!mounted) return;
      if (closeAfter) {
        Navigator.of(context).maybePop();
        return;
      }
      if (reloadAfter) {
        final revision = _revision;
        if (revision != null) {
          await _load(revision.currentRevision);
        }
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
      if (mounted) {
        ToastService.showError(context.l10n.postRevision_actionFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    bool destructive = false,
  }) async {
    final result = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.l10n.common_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: destructive
                  ? TextButton.styleFrom(foregroundColor: theme.colorScheme.error)
                  : null,
              child: Text(dialogContext.l10n.common_confirm),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _revision == null) {
      return const Center(child: LoadingSpinner(size: 36));
    }
    if (_error != null && _revision == null) {
      return _ErrorView(error: _error!, onRetry: () => _load(widget.initialRevision));
    }
    final revision = _revision;
    if (revision == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(context.l10n.postRevision_emptyHistory),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RevisionToolbar(
              revision: revision,
              diffMode: _diffMode,
              onModeChanged: revision.bodyChanges == null
                  ? null
                  : (mode) => setState(() => _diffMode = mode),
              onFirst: revision.currentRevision == revision.firstRevision
                  ? null
                  : () => _navigateTo(revision.firstRevision),
              onPrevious: revision.hasPreviousRevision
                  ? () => _navigateTo(revision.previousRevision)
                  : null,
              onNext: revision.hasNextRevision
                  ? () => _navigateTo(revision.nextRevision!)
                  : null,
              onLast: revision.currentRevision == revision.lastRevision
                  ? null
                  : () => _navigateTo(revision.lastRevision),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AuthorMeta(revision: revision),
                    if (revision.hasMetaChanges) ...[
                      const SizedBox(height: 12),
                      _MetaChanges(revision: revision),
                    ],
                    const SizedBox(height: 16),
                    _BodyDiff(revision: revision, mode: _diffMode),
                  ],
                ),
              ),
            ),
            _StaffActions(
              revision: revision,
              busy: _busy,
              onHide: _hideRevision,
              onShow: _showRevision,
              onRevert: _revertRevision,
              onPermanentlyDelete: _permanentlyDelete,
            ),
          ],
        ),
        if (_busy || (_loading && _revision != null))
          const Positioned.fill(child: _BlockingOverlay()),
      ],
    );
  }
}

/// 顶部紧凑工具栏:左侧导航(上一版/版本号/下一版),右侧 diff 模式 + 溢出菜单(首版/末版)。
/// 桌面端把全部按钮平铺,移动端隐藏首版/末版到溢出菜单。
class _RevisionToolbar extends StatelessWidget {
  final PostRevision revision;
  final _DiffMode diffMode;
  final ValueChanged<_DiffMode>? onModeChanged;
  final VoidCallback? onFirst;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onLast;

  const _RevisionToolbar({
    required this.revision,
    required this.diffMode,
    required this.onModeChanged,
    required this.onFirst,
    required this.onPrevious,
    required this.onNext,
    required this.onLast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isMobile = Responsive.isMobile(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          if (!isMobile)
            IconButton(
              icon: const Icon(Icons.first_page),
              tooltip: l10n.postRevision_first,
              onPressed: onFirst,
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: l10n.postRevision_previous,
            onPressed: onPrevious,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Center(
              child: Text(
                l10n.postRevision_versionLabel(
                  revision.currentVersion,
                  revision.versionCount,
                ),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: l10n.postRevision_next,
            onPressed: onNext,
            visualDensity: VisualDensity.compact,
          ),
          if (!isMobile)
            IconButton(
              icon: const Icon(Icons.last_page),
              tooltip: l10n.postRevision_last,
              onPressed: onLast,
              visualDensity: VisualDensity.compact,
            ),
          if (onModeChanged != null)
            SwipeDismissiblePopupMenuButton<_DiffMode>(
              tooltip: _modeLabel(l10n, diffMode),
              icon: Icon(_modeIcon(diffMode)),
              onSelected: onModeChanged,
              itemBuilder: (_) => [
                for (final mode in _DiffMode.values)
                  PopupMenuItem(
                    value: mode,
                    child: Row(
                      children: [
                        Icon(_modeIcon(mode), size: 18),
                        const SizedBox(width: 8),
                        Text(_modeLabel(l10n, mode)),
                        if (mode == diffMode) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          if (isMobile && (onFirst != null || onLast != null))
            SwipeDismissiblePopupMenuButton<String>(
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'first') onFirst?.call();
                if (value == 'last') onLast?.call();
              },
              itemBuilder: (_) => [
                if (onFirst != null)
                  PopupMenuItem(
                    value: 'first',
                    child: Row(
                      children: [
                        const Icon(Icons.first_page, size: 18),
                        const SizedBox(width: 8),
                        Text(l10n.postRevision_first),
                      ],
                    ),
                  ),
                if (onLast != null)
                  PopupMenuItem(
                    value: 'last',
                    child: Row(
                      children: [
                        const Icon(Icons.last_page, size: 18),
                        const SizedBox(width: 8),
                        Text(l10n.postRevision_last),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static IconData _modeIcon(_DiffMode mode) {
    switch (mode) {
      case _DiffMode.inline:
        return Icons.view_agenda_outlined;
      case _DiffMode.sideBySide:
        return Icons.view_column_outlined;
      case _DiffMode.sideBySideMarkdown:
        return Icons.code;
    }
  }

  static String _modeLabel(AppLocalizations l10n, _DiffMode mode) {
    switch (mode) {
      case _DiffMode.inline:
        return l10n.postRevision_diffInline;
      case _DiffMode.sideBySide:
        return l10n.postRevision_diffSideBySide;
      case _DiffMode.sideBySideMarkdown:
        return l10n.postRevision_diffSideBySideMarkdown;
    }
  }
}

class _AuthorMeta extends StatelessWidget {
  final PostRevision revision;

  const _AuthorMeta({required this.revision});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final avatarUrl = revision.getAvatarUrl();
    final timeText = TimeUtils.formatDetailTime(revision.createdAt);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (avatarUrl.isNotEmpty)
                SmartAvatar(imageUrl: avatarUrl, radius: 16),
              if (avatarUrl.isNotEmpty) const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.postRevision_editedBy(
                        revision.actingUserName ?? revision.displayActor,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      timeText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (revision.currentHidden)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.postRevision_revisionHidden,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            revision.editReason != null
                ? l10n.postRevision_editReason(revision.editReason!)
                : l10n.postRevision_editReasonEmpty,
            style: theme.textTheme.bodySmall?.copyWith(
              color: revision.editReason != null
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
              fontStyle: revision.editReason == null
                  ? FontStyle.italic
                  : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChanges extends ConsumerWidget {
  final PostRevision revision;

  const _MetaChanges({required this.revision});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final categoryMap =
        ref.watch(categoryMapProvider).whenOrNull(data: (m) => m) ?? const {};

    final entries = <_MetaEntry>[];
    final title = revision.titleChanges;
    if (title != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_titleChange,
        previous: title.previous ?? '—',
        current: title.current ?? '—',
      ));
    }
    final category = revision.categoryIdChanges;
    if (category != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_categoryChange,
        previous: _categoryName(categoryMap, category.previous),
        current: _categoryName(categoryMap, category.current),
      ));
    }
    final tags = revision.tagsChanges;
    if (tags != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_tagsChange,
        previous: tags.previous?.join(', ') ?? '—',
        current: tags.current?.join(', ') ?? '—',
      ));
    }
    final wiki = revision.wikiChanges;
    if (wiki != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_wikiChange,
        previous: '${wiki.previous ?? false}',
        current: '${wiki.current ?? false}',
      ));
    }
    final postType = revision.postTypeChanges;
    if (postType != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_postTypeChange,
        previous: '${postType.previous}',
        current: '${postType.current}',
      ));
    }
    final replyTo = revision.replyToPostNumberChanges;
    if (replyTo != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_replyToChange,
        previous: replyTo.previous != null ? '#${replyTo.previous}' : '—',
        current: replyTo.current != null ? '#${replyTo.current}' : '—',
      ));
    }
    final user = revision.userChanges;
    if (user != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_userChange,
        previous: user.previousUsername ?? '—',
        current: user.currentUsername ?? '—',
      ));
    }
    final locale = revision.localeChanges;
    if (locale != null) {
      entries.add(_MetaEntry(
        label: l10n.postRevision_localeChange,
        previous: locale.previous ?? '—',
        current: locale.current ?? '—',
      ));
    }

    if (entries.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 16),
            _MetaRow(entry: entries[i]),
          ],
        ],
      ),
    );
  }

  String _categoryName(Map<int, dynamic> map, int? id) {
    if (id == null) return '—';
    final category = map[id];
    if (category == null) return '#$id';
    final name = (category as dynamic).name as String?;
    return name == null || name.isEmpty ? '#$id' : name;
  }
}

class _MetaEntry {
  final String label;
  final String previous;
  final String current;

  const _MetaEntry({
    required this.label,
    required this.previous,
    required this.current,
  });
}

class _MetaRow extends StatelessWidget {
  final _MetaEntry entry;

  const _MetaRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delBg = theme.colorScheme.errorContainer.withValues(alpha: 0.4);
    final insBg = theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            entry.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              _MetaChip(text: entry.previous, color: delBg, strike: true),
              const Icon(Icons.arrow_right_alt, size: 18),
              _MetaChip(text: entry.current, color: insBg, strike: false),
            ],
          ),
        ),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String text;
  final Color color;
  final bool strike;

  const _MetaChip({
    required this.text,
    required this.color,
    required this.strike,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          decoration: strike ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }
}

class _BodyDiff extends StatelessWidget {
  final PostRevision revision;
  final _DiffMode mode;

  const _BodyDiff({required this.revision, required this.mode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (revision.diffError) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          context.l10n.postRevision_diffError,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
      );
    }
    final body = revision.bodyChanges;
    if (body == null || body.isEmpty) {
      return const SizedBox.shrink();
    }

    switch (mode) {
      case _DiffMode.inline:
        final html = body.inline ?? body.sideBySide ?? body.sideBySideMarkdown;
        if (html == null || html.isEmpty) return const SizedBox.shrink();
        return DiscourseHtmlContent(html: html, enableSelectionArea: false);

      case _DiffMode.sideBySide:
        final raw = body.sideBySide ?? body.sideBySideMarkdown ?? body.inline;
        if (raw == null || raw.isEmpty) return const SizedBox.shrink();
        // 后端返回两个并排 div: `<div class="revision-content --previous">A</div><div class="revision-content --current">B</div>`
        // flutter_widget_from_html 不识别 CSS grid,拆开用 Row 渲染。
        final parts = _splitSideBySide(raw);
        if (parts == null) {
          return DiscourseHtmlContent(html: raw, enableSelectionArea: false);
        }
        return _TwoColumnDiff(
          previousHtml: parts.$1,
          currentHtml: parts.$2,
        );

      case _DiffMode.sideBySideMarkdown:
        final raw = body.sideBySideMarkdown ?? body.sideBySide ?? body.inline;
        if (raw == null || raw.isEmpty) return const SizedBox.shrink();
        // markdown 模式后端给的是 <table>:每行两个 td (--previous / --current),内容是 markdown raw 文本。
        // 直接渲染 table 会触发自定义 table_builder 的固定列宽 + 虚拟化(出现 1/1391 滚动指示器)。
        // 拆成左右两列原始 markdown 文本,各自渲染到 _TwoColumnDiff。
        final parts = _splitSideBySideMarkdown(raw);
        if (parts == null) {
          return DiscourseHtmlContent(html: raw, enableSelectionArea: false);
        }
        return _TwoColumnDiff(
          previousHtml: parts.$1,
          currentHtml: parts.$2,
          preformatted: true,
        );
    }
  }

  /// 拆 discourse 的 `<div class="revision-content --previous">…</div><div class="revision-content --current">…</div>`
  /// 成 `(previous, current)` 两段 HTML; 任一缺失返回 null,由上层 fallback 直接渲染原 HTML。
  static (String, String)? _splitSideBySide(String raw) {
    final pattern = RegExp(
      r'<div\s+class="revision-content\s+--previous">([\s\S]*?)</div>\s*<div\s+class="revision-content\s+--current">([\s\S]*?)</div>\s*$',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return (match.group(1) ?? '', match.group(2) ?? '');
  }

  /// 拆 discourse 的 `<table class="markdown"><tr><td class="--previous ...">A</td><td class="--current ...">B</td></tr>...</table>`
  /// 按行配对成 `(previousLines, currentLines)`,每行用 `<div>` 包(继承 diff-ins/del class 着色)。
  static (String, String)? _splitSideBySideMarkdown(String raw) {
    final rowPattern = RegExp(
      r'<tr>\s*<td\s+class="([^"]*?)">([\s\S]*?)</td>\s*<td\s+class="([^"]*?)">([\s\S]*?)</td>\s*</tr>',
      caseSensitive: false,
    );
    final matches = rowPattern.allMatches(raw).toList();
    if (matches.isEmpty) return null;
    final previousBuf = StringBuffer();
    final currentBuf = StringBuffer();
    for (final m in matches) {
      final prevClasses = m.group(1) ?? '';
      final prevContent = m.group(2) ?? '';
      final currClasses = m.group(3) ?? '';
      final currContent = m.group(4) ?? '';
      previousBuf.write('<div class="$prevClasses">$prevContent</div>');
      currentBuf.write('<div class="$currClasses">$currContent</div>');
    }
    return (previousBuf.toString(), currentBuf.toString());
  }
}

class _TwoColumnDiff extends StatelessWidget {
  final String previousHtml;
  final String currentHtml;
  /// markdown 模式下内容是原始 markdown 文本(含 \n 与空白),用等宽字体并保留空白。
  final bool preformatted;

  const _TwoColumnDiff({
    required this.previousHtml,
    required this.currentHtml,
    this.preformatted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delBorder = theme.colorScheme.error.withValues(alpha: 0.25);
    final insBorder = theme.colorScheme.tertiary.withValues(alpha: 0.3);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _DiffColumn(
            html: previousHtml,
            borderColor: delBorder,
            preformatted: preformatted,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _DiffColumn(
            html: currentHtml,
            borderColor: insBorder,
            preformatted: preformatted,
          ),
        ),
      ],
    );
  }
}

class _DiffColumn extends StatelessWidget {
  final String html;
  final Color borderColor;
  final bool preformatted;

  const _DiffColumn({
    required this.html,
    required this.borderColor,
    this.preformatted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // markdown 模式:用等宽字体 + 保留换行;DiscourseHtmlContent 不识别 white-space:pre,
    // 直接把 raw 文本里的 \n 替换成 <br/> 让渲染保留行结构。
    final processed = preformatted ? html.replaceAll('\n', '<br/>') : html;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DiscourseHtmlContent(
        html: processed,
        enableSelectionArea: false,
        textStyle: preformatted
            ? theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              )
            : null,
      ),
    );
  }
}

class _StaffActions extends ConsumerWidget {
  final PostRevision revision;
  final bool busy;
  final VoidCallback onHide;
  final VoidCallback onShow;
  final VoidCallback onRevert;
  final VoidCallback onPermanentlyDelete;

  const _StaffActions({
    required this.revision,
    required this.busy,
    required this.onHide,
    required this.onShow,
    required this.onRevert,
    required this.onPermanentlyDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUser = ref.watch(currentUserProvider).value;
    if (currentUser == null || !currentUser.isStaff) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: [
          if (revision.currentHidden)
            OutlinedButton.icon(
              onPressed: busy ? null : onShow,
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: Text(l10n.postRevision_show),
            )
          else
            OutlinedButton.icon(
              onPressed: busy ? null : onHide,
              icon: const Icon(Icons.visibility_off_outlined, size: 16),
              label: Text(l10n.postRevision_hide),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          if (revision.hasPreviousRevision)
            OutlinedButton.icon(
              onPressed: busy ? null : onRevert,
              icon: const Icon(Icons.history, size: 16),
              label: Text(l10n.postRevision_revert),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          if (revision.previousHidden)
            OutlinedButton.icon(
              onPressed: busy ? null : onPermanentlyDelete,
              icon: const Icon(Icons.delete_forever_outlined, size: 16),
              label: Text(l10n.postRevision_permanentlyDelete),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

class _BlockingOverlay extends StatelessWidget {
  const _BlockingOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.55),
      child: const Center(child: LoadingSpinner(size: 32)),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                color: theme.colorScheme.error, size: 36),
            const SizedBox(height: 12),
            Text(
              l10n.postRevision_loadFailed,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onRetry,
              child: Text(l10n.postRevision_retry),
            ),
          ],
        ),
      ),
    );
  }
}
