import 'package:app_icons/app_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../services/linux_do_connect_oauth_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../metaverse_plugin_manifest.dart';

Future<bool> showMetaverseConnectConfirmation(
  BuildContext context, MetaversePluginManifest manifest, String username, {
  required Uri callback,
}) async => await showAppDialog<bool>(
  context: context,
  builder: (_) => LinuxDoConnectAuthDialog(
    title: context.l10n.metaverse_nativeLoginTitle(manifest.name),
    message: context.l10n.metaverse_nativeLoginAccess,
    details: SegmentedCardGroup(children: [
      ListTile(leading: const Icon(Symbols.person_rounded),
        title: Text(context.l10n.metaverse_nativeLoginAccount(username))),
      ListTile(leading: const Icon(Symbols.public_rounded),
        title: Text(manifest.name), subtitle: Text(callback.host)),
    ]),
    onApprove: () async => true,
  ),
) ?? false;
