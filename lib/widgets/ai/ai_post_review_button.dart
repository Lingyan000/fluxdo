import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:popover/popover.dart';

import '../../l10n/s.dart';
import '../../providers/ai_post_review_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../services/ai_post_review_service.dart';
import '../../services/toast_service.dart';

class AiPostReviewButton extends ConsumerStatefulWidget {
  const AiPostReviewButton({
    super.key,
    required this.titleBuilder,
    required this.contentBuilder,
    required this.target,
    this.enabled = true,
    this.categoryNameBuilder,
    this.categoryDescriptionBuilder,
    this.tagsBuilder,
  });

  final String? Function() titleBuilder;
  final String Function() contentBuilder;
  final AiPostReviewTarget target;
  final bool enabled;
  final String? Function()? categoryNameBuilder;
  final String? Function()? categoryDescriptionBuilder;
  final List<String> Function()? tagsBuilder;

  @override
  ConsumerState<AiPostReviewButton> createState() => _AiPostReviewButtonState();
}

class _AiPostReviewButtonState extends ConsumerState<AiPostReviewButton> {
  bool _isReviewing = false;

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      preferencesProvider.select((prefs) => prefs.aiPostReviewEnabled),
    );
    if (!enabled) return const SizedBox.shrink();

    return Builder(
      builder: (anchorContext) {
        return TextButton(
          onPressed: _isReviewing || !widget.enabled
              ? null
              : () => _runReview(anchorContext),
          child: _isReviewing
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(context.l10n.aiPostReview_reviewing),
                  ],
                )
              : Text(context.l10n.aiPostReview_button),
        );
      },
    );
  }

  Future<void> _runReview(BuildContext anchorContext) async {
    final content = widget.contentBuilder().trim();
    if (content.isEmpty) {
      ToastService.showInfo(context.l10n.aiPostReview_contentRequired);
      return;
    }

    final selected = ref.read(aiPostReviewSelectedModelProvider);
    if (selected == null) {
      ToastService.showInfo(context.l10n.aiPostReview_noAvailableModel);
      return;
    }

    setState(() => _isReviewing = true);
    try {
      final service = ref.read(aiPostReviewServiceProvider);
      final result = await service.review(
        AiPostReviewRequest(
          provider: selected.provider,
          model: selected.model,
          title: widget.titleBuilder(),
          content: content,
          target: widget.target,
          categoryName: widget.categoryNameBuilder?.call(),
          categoryDescription: widget.categoryDescriptionBuilder?.call(),
          tags: List.unmodifiable(widget.tagsBuilder?.call() ?? const []),
        ),
      );
      if (!mounted || !anchorContext.mounted) return;
      await _showReviewResult(anchorContext, result);
    } on AiPostReviewException catch (error) {
      if (!mounted) return;
      _showReviewError(error.message, details: error.details);
    } catch (error, stackTrace) {
      if (!mounted) return;
      _showReviewError(
        context.l10n.aiPostReview_failed,
        details: '$error\n$stackTrace',
      );
    } finally {
      if (mounted) setState(() => _isReviewing = false);
    }
  }

  Future<void> _showReviewResult(
    BuildContext anchorContext,
    AiPostReviewResult result,
  ) {
    final theme = Theme.of(anchorContext);
    return showPopover(
      context: anchorContext,
      bodyBuilder: (popoverContext) => _AiPostReviewPopover(result: result),
      direction: PopoverDirection.bottom,
      arrowHeight: 8,
      arrowWidth: 12,
      backgroundColor: theme.colorScheme.surface,
      barrierColor: Colors.transparent,
      radius: 8,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.15),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  void _showReviewError(String message, {String? details}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final copyDetailsLabel = context.l10n.aiPostReview_copyDetails;
    final detailsCopiedMessage = context.l10n.aiPostReview_detailsCopied;
    if (messenger == null) {
      ToastService.showInfo(message);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: details == null || details.isEmpty
              ? null
              : SnackBarAction(
                  label: copyDetailsLabel,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: details));
                    ToastService.showInfo(detailsCopiedMessage);
                  },
                ),
        ),
      );
  }
}

class _AiPostReviewPopover extends StatelessWidget {
  const _AiPostReviewPopover({required this.result});

  final AiPostReviewResult result;

  @override
  Widget build(BuildContext context) {
    final tone = _toneFor(result.level);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LevelHeader(
              tone: tone,
              levelText: _levelText(context, result.level),
            ),
            if (result.usedCachedGuidelines) ...[
              const SizedBox(height: 12),
              _CacheNotice(text: context.l10n.aiPostReview_cachedGuidelines),
            ],
            const SizedBox(height: 14),
            _SuggestionList(items: result.suggestions, tone: tone),
          ],
        ),
      ),
    );
  }

  _ReviewTone _toneFor(AiPostReviewLevel level) {
    return switch (level) {
      AiPostReviewLevel.low => const _ReviewTone(
        color: Color(0xFF2E7D32),
        icon: Icons.check_circle_outline_rounded,
      ),
      AiPostReviewLevel.medium => const _ReviewTone(
        color: Color(0xFFF57C00),
        icon: Icons.error_outline_rounded,
      ),
      AiPostReviewLevel.high => const _ReviewTone(
        color: Color(0xFFC62828),
        icon: Icons.warning_amber_rounded,
      ),
    };
  }

  String _levelText(BuildContext context, AiPostReviewLevel level) {
    return switch (level) {
      AiPostReviewLevel.low => context.l10n.aiPostReview_levelLow,
      AiPostReviewLevel.medium => context.l10n.aiPostReview_levelMedium,
      AiPostReviewLevel.high => context.l10n.aiPostReview_levelHigh,
    };
  }
}

class _ReviewTone {
  const _ReviewTone({required this.color, required this.icon});

  final Color color;
  final IconData icon;
}

class _LevelHeader extends StatelessWidget {
  const _LevelHeader({required this.tone, required this.levelText});

  final _ReviewTone tone;
  final String levelText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone.color.withValues(alpha: 0.10),
        border: Border.all(color: tone.color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(tone.icon, size: 20, color: tone.color),
          const SizedBox(width: 8),
          Text(
            context.l10n.aiPostReview_levelLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: tone.color,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              levelText,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.items, required this.tone});

  final List<String> items;
  final _ReviewTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (index > 0)
            Divider(
              height: 18,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tone.color,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    items[index],
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CacheNotice extends StatelessWidget {
  const _CacheNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
