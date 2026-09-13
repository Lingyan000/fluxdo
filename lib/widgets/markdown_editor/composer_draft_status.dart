import 'dart:async';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/draft_controller.dart';
import '../common/character_counts_overlay.dart';

/// 草稿与字数共用正文底部的反馈区，不占用顶栏标题或改变文档布局。
class ComposerStatusBar extends StatelessWidget {
  const ComposerStatusBar({
    super.key,
    required this.length,
    this.minimumLength,
    this.draftStatus,
    this.onRetry,
  });

  final int length;
  final int? minimumLength;
  final ValueListenable<DraftSaveStatus>? draftStatus;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final counter = CharacterCountsOverlay(
      length: length,
      minimumLength: minimumLength,
    );
    if (draftStatus == null) return counter;
    final draft = ComposerDraftStatus(status: draftStatus!, onRetry: onRetry);
    if (minimumLength == null || minimumLength! <= length) {
      return Align(alignment: Alignment.centerLeft, child: draft);
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        // 窄屏和大字体分行，保存失败及字数要求都能完整读到。
        if (bounds.maxWidth < 320 ||
            MediaQuery.textScalerOf(context).scale(12) > 16) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(alignment: Alignment.centerLeft, child: draft),
              Align(alignment: Alignment.centerRight, child: counter),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: draft),
            const SizedBox(width: 12),
            Flexible(child: counter),
          ],
        );
      },
    );
  }
}

/// 成功反馈短暂显示；失败常驻并可重试。快速保存不闪烁加载动画。
class ComposerDraftStatus extends StatefulWidget {
  const ComposerDraftStatus({super.key, required this.status, this.onRetry});

  final ValueListenable<DraftSaveStatus> status;
  final Future<void> Function()? onRetry;

  @override
  State<ComposerDraftStatus> createState() => _ComposerDraftStatusState();
}

class _ComposerDraftStatusState extends State<ComposerDraftStatus> {
  late DraftSaveStatus _status;
  Timer? _timer;
  bool _visible = false;
  bool _showSpinner = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    widget.status.addListener(_changed);
    _readStatus();
  }

  @override
  void didUpdateWidget(covariant ComposerDraftStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      oldWidget.status.removeListener(_changed);
      widget.status.addListener(_changed);
      _readStatus();
    }
  }

  void _changed() => setState(_readStatus);

  void _readStatus() {
    _timer?.cancel();
    _status = widget.status.value;
    _visible = _status != DraftSaveStatus.idle;
    _showSpinner = false;
    if (_status == DraftSaveStatus.saved) {
      _timer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _visible = false);
      });
    } else if (_status == DraftSaveStatus.saving) {
      _timer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _showSpinner = true);
      });
    }
  }

  Future<void> _retry() async {
    if (_retrying || widget.onRetry == null) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry!();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  void dispose() {
    widget.status.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final error = _status == DraftSaveStatus.error;
    final label = switch (_status) {
      DraftSaveStatus.idle => '',
      DraftSaveStatus.pending => context.l10n.composer_draftPending,
      DraftSaveStatus.saving => context.l10n.composer_draftSaving,
      DraftSaveStatus.saved => context.l10n.composer_draftSaved,
      DraftSaveStatus.error => context.l10n.composer_draftError,
    };
    final color = error ? colors.error : colors.onSurfaceVariant;
    final icon = switch (_status) {
      DraftSaveStatus.saved => Symbols.cloud_done_rounded,
      DraftSaveStatus.error => Symbols.cloud_off_rounded,
      _ => Symbols.cloud_upload_rounded,
    };
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showSpinner && !reduced)
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
          )
        else
          Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            error && widget.onRetry != null
                ? '$label · ${context.l10n.common_retry}'
                : label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
    return TextFieldTapRegion(
      child: IgnorePointer(
        ignoring: !_visible || !error || _retrying,
        child: AnimatedSwitcher(
          duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
          reverseDuration: reduced
              ? Duration.zero
              : const Duration(milliseconds: 120),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.centerLeft,
            children: [
              for (final child in previous)
                IgnorePointer(child: ExcludeSemantics(child: child)),
              ?current,
            ],
          ),
          child: !_visible
              ? const SizedBox.shrink()
              : Semantics(
                  key: ValueKey(_status),
                  liveRegion: error || _status == DraftSaveStatus.saved,
                  child: Material(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(6),
                    child: error && widget.onRetry != null
                        ? TextButton(
                            key: const ValueKey('composer-draft-retry'),
                            onPressed: _retrying ? null : _retry,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              foregroundColor: colors.error,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            child: content,
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: content,
                          ),
                  ),
                ),
        ),
      ),
    );
  }
}
