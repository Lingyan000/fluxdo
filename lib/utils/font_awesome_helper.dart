import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'font_awesome_name_mapping.dart';

class FontAwesomeHelper {
  static FaIconData? getIcon(String? name) {
    if (name == null) return null;
    final raw = name.trim().toLowerCase();
    if (raw.isEmpty) return null;

    // Try parse css-like class names first (fa-*, fas fa-*, far fa-*, fab fa-*)
    FaIconData? icon;
    if (raw.contains('fa-') || raw.contains('fa ')) {
      final normalized = raw
          .replaceAll('fa-solid', 'fas')
          .replaceAll('fa-regular', 'far')
          .replaceAll('fa-brands', 'fab')
          .replaceAll('fa-light', 'fal')
          .replaceAll('fa-thin', 'fat')
          .replaceAll('fa-duotone', 'fad');
      try {
        icon = getIconFromCss(normalized);
      } catch (_) {
        icon = null;
      }
      if (icon != null) return icon;
    }

    // Fallback to direct name mapping.
    final clean = raw
        .replaceAll('fa-', '')
        .replaceAll('fas-', '')
        .replaceAll('far-', '')
        .replaceAll('fab-', '')
        .replaceAll('fas ', '')
        .replaceAll('far ', '')
        .replaceAll('fab ', '')
        .replaceAll('fa ', '');

    for (final style in const ['solid', 'regular', 'brands']) {
      icon = faIconNameMapping['$style $clean'];
      if (icon != null) return icon;
    }

    return null;
  }
}
