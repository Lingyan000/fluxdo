import 'package:flutter/material.dart';

import '../l10n/s.dart';
import '../settings/definitions/appearance_defs.dart';
import '../widgets/settings/settings_group_page.dart';
import 'preferences_page.dart';

class AppearancePage extends StatelessWidget {
  final String? highlightId;

  const AppearancePage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    if (highlightId == 'language') {
      return const PreferencesPage(highlightId: 'language');
    }
    final section = appearanceSectionForSetting(highlightId);
    if (section != null) {
      return AppearanceSectionPage(section: section, highlightId: highlightId);
    }
    return SettingsGroupPage(
      title: context.l10n.appearance_title,
      groupsBuilder: buildAppearanceGroups,
      highlightId: highlightId,
      maxContentWidth: 720,
    );
  }
}
