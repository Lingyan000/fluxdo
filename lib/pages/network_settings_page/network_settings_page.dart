import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../settings/definitions/network_defs.dart';
import '../../widgets/settings/settings_group_page.dart';

/// 网络设置页面
class NetworkSettingsPage extends StatelessWidget {
  final String? highlightId;

  const NetworkSettingsPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.networkSettings_title,
      groupsBuilder: buildNetworkGroups,
      highlightId: highlightId,
    );
  }
}
