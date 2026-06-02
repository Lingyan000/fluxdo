import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../l10n/s.dart';
import '../services/update_service.dart';

class UpdateDialog extends StatelessWidget {
  final UpdateInfo updateInfo;
  final VoidCallback onUpdate;
  final VoidCallback onCancel;
  final VoidCallback? onIgnore;
  final VoidCallback? onOpenReleasePage;

  const UpdateDialog({
    super.key,
    required this.updateInfo,
    required this.onUpdate,
    required this.onCancel,
    this.onIgnore,
    this.onOpenReleasePage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final maxContentHeight = size.height * 0.5;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 0,
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 25,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Decorative Watermark (Background)
            Positioned(
              right: -30,
              top: -20,
              child: Icon(
                Icons.rocket_launch_rounded,
                size: 200,
                color: colorScheme.primary.withValues(alpha: 0.05),
              ),
            ),
            
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header (Compact)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                           Icons.auto_awesome, 
                           color: colorScheme.onPrimaryContainer,
                           size: 20,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.update_newVersionFound,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 2),
                           Row(
                              children: [
                                _buildVersionText(context,
                                    updateInfo.currentVersion, false),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6),
                                  child: Icon(
                                    Icons.arrow_right_alt_rounded,
                                    size: 16,
                                    color: colorScheme.outline,
                                  ),
                                ),
                                _buildVersionText(context,
                                    updateInfo.remoteVersion, true),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Content
                if (updateInfo.releaseNotes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Text(
                      context.l10n.update_changelog,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                
                if (updateInfo.releaseNotes.isNotEmpty)
                  Container(
                    constraints: BoxConstraints(maxHeight: maxContentHeight),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: HtmlWidget(
                        md.markdownToHtml(updateInfo.releaseNotes),
                        textStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.5,
                          fontSize: 14,
                        ),
                        customStylesBuilder: (element) {
                          if (element.localName == 'ul' ||
                              element.localName == 'ol') {
                            return {'padding-left': '20px'};
                          }
                          return null;
                        },
                        onTapUrl: (url) async {
                           return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                        },
                      ),
                    ),
                  ),

                // Actions
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton(
                        onPressed: onUpdate,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(context.l10n.update_now,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (onIgnore != null)
                            TextButton(
                              onPressed: onIgnore,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                foregroundColor: colorScheme.onSurfaceVariant.withValues(alpha:0.7),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(context.l10n.update_dontRemind, style: const TextStyle(fontSize: 13)),
                            ),
                          if (onOpenReleasePage != null)
                             TextButton(
                              onPressed: onOpenReleasePage,
                                style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                foregroundColor: colorScheme.primary,
                                 minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(context.l10n.common_viewDetails, style: const TextStyle(fontSize: 13)),
                            ),
                          const Spacer(),
                          TextButton(
                            onPressed: onCancel,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              foregroundColor: colorScheme.onSurfaceVariant,
                               minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(context.l10n.common_later, style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVersionText(BuildContext context, String version, bool isNew) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
         color: isNew ? colorScheme.primary.withValues(alpha: 0.1) : colorScheme.surfaceContainerHighest,
         borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'v$version',
        style: TextStyle(
          fontSize: 12,
          fontWeight: isNew ? FontWeight.w600 : FontWeight.normal,
          color: isNew ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
