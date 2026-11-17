import 'package:material_ui/material_ui.dart';

import '../l10n/s.dart';
import '../settings/definitions/preferences_defs.dart';
import '../widgets/settings/settings_group_page.dart';

class PreferencesPage extends StatelessWidget {
  final String? highlightId;

  const PreferencesPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.preferences_title,
      groupsBuilder: buildPreferencesGroups,
      highlightId: highlightId,
    );
  }
}
