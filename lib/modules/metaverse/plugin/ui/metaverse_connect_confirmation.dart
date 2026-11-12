import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../utils/link_launcher.dart';
import '../metaverse_plugin_manifest.dart';

Future<bool> showMetaverseConnectConfirmation(
  BuildContext context,
  MetaversePluginManifest manifest,
  String username, {
  Uri? callback,
  Uri? terms,
}) async {
  final destination =
      callback ?? Uri.parse(manifest.auth.connect!['callback']!);
  final legacyTerms = manifest.auth.connect?['terms'];
  final termsUri =
      terms ?? (legacyTerms == null ? null : Uri.parse(legacyTerms));
  return await showAppDialog<bool>(
        context: context,
        builder: (_) => _ConnectConfirmation(
          manifest: manifest,
          username: username,
          callback: destination,
          terms: termsUri,
        ),
      ) ??
      false;
}

class _ConnectConfirmation extends StatefulWidget {
  const _ConnectConfirmation({
    required this.manifest,
    required this.username,
    required this.callback,
    this.terms,
  });
  final MetaversePluginManifest manifest;
  final String username;
  final Uri callback;
  final Uri? terms;
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
            widget.callback.host,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (widget.terms != null)
            TextButton(
              onPressed: () =>
                  launchExternalLink(context, widget.terms.toString()),
              child: Text(context.l10n.metaverse_nativeTerms),
            ),
          if (widget.terms != null)
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
        onPressed: _accepted || widget.terms == null
            ? () => Navigator.pop(context, true)
            : null,
        child: Text(context.l10n.common_allow),
      ),
    ],
  );
}
