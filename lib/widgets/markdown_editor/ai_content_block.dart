import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../services/preloaded_data_service.dart';

enum AiContentBlock {
  code,
  quote,
  details;

  static Iterable<AiContentBlock> get available => values.where(
    (block) =>
        block != details ||
        PreloadedDataService().siteSettingsSync?['details_enabled'] == true,
  );

  String label(AppLocalizations s) => switch (this) {
    code => s.editor_aiCode,
    quote => s.editor_aiQuote,
    details => s.editor_aiDetails,
  };

  IconData get icon => switch (this) {
    code => Icons.code_rounded,
    quote => Icons.format_quote_rounded,
    details => Icons.expand_circle_down_outlined,
  };

  String markdown(AppLocalizations s, String selected) {
    final body = selected.isEmpty ? s.toolbar_calloutPlaceholder : selected;
    switch (this) {
      case code:
        final fence = RegExp(r'`+')
            .allMatches(body)
            .fold(
              '```',
              (fence, match) => match.end - match.start >= fence.length
                  ? '`' * (match.end - match.start + 1)
                  : fence,
            );
        return '$fence ai\n$body\n$fence';
      case quote:
        return '> [!AI]\n${body.split('\n').map((line) => '> $line').join('\n')}';
      case details:
        return '[details="${s.editor_aiDetailsTitle}" ai]\n$body\n[/details]';
    }
  }
}
