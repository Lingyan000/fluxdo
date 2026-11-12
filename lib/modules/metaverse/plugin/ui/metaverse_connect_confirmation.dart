import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../utils/link_launcher.dart';
import '../metaverse_plugin_manifest.dart';

Future<bool> showMetaverseConnectConfirmation(
  BuildContext context,
  MetaversePluginManifest manifest,
  String username,
) async {
  return await showAppDialog<bool>(
        context: context,
        builder: (_) =>
            _ConnectConfirmation(manifest: manifest, username: username),
      ) ??
      false;
}

class _ConnectConfirmation extends StatefulWidget {
  const _ConnectConfirmation({required this.manifest, required this.username});
  final MetaversePluginManifest manifest;
  final String username;
  @override
  State<_ConnectConfirmation> createState() => _ConnectConfirmationState();
}

class _ConnectConfirmationState extends State<_ConnectConfirmation> {
  bool _accepted = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.metaverse_nativeLoginTitle(widget.manifest.name)),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.metaverse_nativeLoginAccount(widget.username)),
          const SizedBox(height: 12),
          Text(context.l10n.metaverse_nativeLoginAccess),
          const SizedBox(height: 8),
          Text(
            Uri.parse(widget.manifest.auth.connect!['callback']!).host,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextButton(
            onPressed: () => launchExternalLink(
              context,
              widget.manifest.auth.connect!['terms']!,
            ),
            child: Text(context.l10n.metaverse_nativeTerms),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _accepted,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(context.l10n.metaverse_nativeTermsAgree),
            onChanged: (value) => setState(() => _accepted = value ?? false),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.common_cancel),
      ),
      FilledButton(
        onPressed: _accepted ? () => Navigator.pop(context, true) : null,
        child: Text(context.l10n.common_allow),
      ),
    ],
  );
}
