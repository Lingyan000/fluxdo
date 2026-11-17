import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';

Future<bool> showMetaverseConfirmation(BuildContext context, String pluginName,
    Map<String, Object?> options) async => await AppBottomSheet.show<bool>(
  context: context,
  title: options['title'] as String,
  showDragHandle: true,
  builder: (_) => MetaverseConfirmationContent(pluginName: pluginName, options: options),
) ?? false;

class MetaverseConfirmationContent extends StatefulWidget {
  const MetaverseConfirmationContent({super.key, required this.pluginName, required this.options});
  final String pluginName;
  final Map<String, Object?> options;
  @override
  State<MetaverseConfirmationContent> createState() => _ConfirmationState();
}

class _ConfirmationState extends State<MetaverseConfirmationContent> {
  bool _accepted = false;
  @override
  Widget build(BuildContext context) {
    final agreement = widget.options['agreement'] as Map?;
    return SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.pluginName, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 16),
        Text(widget.options['message'] as String),
        if (agreement != null) ...[
          const SizedBox(height: 20),
          SegmentedCardGroup(children: [ListTile(
            leading: Icon(Symbols.description_rounded, color: context.emphasis.accent),
            title: Text(agreement['label'] as String),
            trailing: const Icon(Symbols.open_in_new_rounded),
            onTap: () => launchExternalLink(context, agreement['url'] as String, mode: LinkOpenMode.inApp),
          )]),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(context.l10n.metaverse_confirmationAccept),
            value: _accepted,
            onChanged: (value) => setState(() => _accepted = value == true),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: agreement == null || _accepted ? () => Navigator.of(context).pop(true) : null,
          child: Text(widget.options['confirmLabel'] as String),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.l10n.common_cancel)),
      ],
    ));
  }
}
