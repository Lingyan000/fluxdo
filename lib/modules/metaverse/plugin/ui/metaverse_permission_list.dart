import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_plugin_permission.dart';

/// 安装审阅和已安装插件的设置共用分类、文案与访问范围。
class MetaversePermissionList extends StatelessWidget {
  const MetaversePermissionList({
    super.key,
    required this.manifest,
    required this.blocked,
    required this.onChanged,
    this.busy = false,
  });
  final MetaversePluginManifest manifest;
  final Set<MetaversePluginPermission> blocked;
  final void Function(MetaversePluginPermission, bool) onChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final permissions = manifest.declaredPermissions.toList();
    final cardColor = PageBackgroundScope.contentColor(
      context,
      Theme.of(context).colorScheme.surfaceContainerLow,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final manageable in [true, false])
          if (permissions.any((p) => p.manageable == manageable)) ...[
            Text(
              manageable
                  ? l.metaverse_managedPermissions
                  : l.metaverse_basicPermissions,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedCardGroup(
              color: cardColor,
              children: [
                for (final permission in permissions.where(
                  (p) => p.manageable == manageable,
                ))
                  _row(context, permission),
              ],
            ),
            const SizedBox(height: 16),
          ],
        if (manifest.networkHosts.isNotEmpty ||
            manifest.linkHosts.isNotEmpty ||
            MetaversePluginPermission.serviceAccount.declaredBy(manifest))
          SegmentedCardGroup(
            color: cardColor,
            children: [
              ExpansionTile(
                title: Text(l.metaverse_permissionScopes),
                children: [
                  if (manifest.networkHosts.isNotEmpty)
                    _details(
                      l.metaverse_permissionNetwork,
                      manifest.networkHosts,
                    ),
                  if (manifest.linkHosts.isNotEmpty)
                    _details(l.metaverse_permissionLinks, manifest.linkHosts),
                  if (MetaversePluginPermission.serviceAccount.declaredBy(
                    manifest,
                  ))
                    _details(l.metaverse_permissionAccount, [
                      for (final callback
                          in manifest.capabilities.connectCallbacks)
                        callback.toString(),
                      for (final credential
                          in manifest.capabilities.credentials.values)
                        for (final scope in credential.scopes)
                          '${scope.methods.join(' / ')} ${scope.origin.origin}${scope.pathPrefix}',
                      ...manifest.auth.hosts,
                      if (manifest.webLogin case final login?) login.toString(),
                    ]),
                ],
              ),
            ],
          ),
      ],
    );
  }

  Widget _details(String label, List<String> items) =>
      ListTile(title: Text(label), subtitle: SelectableText(items.join('\n')));

  Widget _row(BuildContext context, MetaversePluginPermission permission) {
    final (icon, title, note) = _presentation(context, manifest, permission);
    final leading = Icon(icon, color: context.emphasis.accent);
    final subtitle = note == null ? null : Text(note);
    if (permission.manageable) {
      return M3eSwitchListTile(
        key: ValueKey(permission),
        secondary: leading,
        title: Text(title),
        subtitle: subtitle,
        value: !blocked.contains(permission),
        onChanged: busy ? null : (allowed) => onChanged(permission, allowed),
      );
    }
    return ListTile(
      key: ValueKey(permission),
      leading: leading,
      title: Text(title),
      subtitle: subtitle,
    );
  }
}

(IconData, String, String?) _presentation(
  BuildContext context,
  MetaversePluginManifest manifest,
  MetaversePluginPermission permission,
) {
  final l = context.l10n;
  return switch (permission) {
    MetaversePluginPermission.sandbox => (
      Symbols.extension_rounded,
      l.metaverse_permissionSandbox,
      l.metaverse_permissionSandboxNote,
    ),
    MetaversePluginPermission.network => (
      Symbols.public_rounded,
      l.metaverse_permissionNetwork,
      l.metaverse_permissionNetworkNote,
    ),
    MetaversePluginPermission.foregroundTasks => (
      Symbols.schedule_rounded,
      l.metaverse_foregroundTasks,
      manifest.tasks.map((task) => manifest.text('tasks.${task.id}.title', task.title, l.localeName)).join(' · '),
    ),
    MetaversePluginPermission.identity => (
      Symbols.person_rounded,
      l.metaverse_permissionIdentity,
      l.metaverse_permissionIdentityNote,
    ),
    MetaversePluginPermission.serviceAccount => (
      Symbols.account_circle_rounded,
      l.metaverse_permissionAccount,
      l.metaverse_permissionAccountNote,
    ),
    MetaversePluginPermission.payments => (
      Symbols.payments_rounded,
      l.metaverse_nativePayTitle,
      l.metaverse_permissionPaymentNote,
    ),
    MetaversePluginPermission.forumProfiles => (
      Symbols.person_rounded,
      l.metaverse_forumProfiles,
      null,
    ),
    MetaversePluginPermission.forumActivity => (
      Symbols.forum_rounded,
      l.metaverse_permissionForumActivity,
      l.metaverse_forumActivity,
    ),
    MetaversePluginPermission.forumFollowing => (
      Symbols.group_rounded,
      l.metaverse_forumFollowing,
      null,
    ),
    MetaversePluginPermission.background => (
      Symbols.schedule_rounded,
      l.metaverse_backgroundTasks,
      l.metaverse_permissionBackgroundNote,
    ),
    MetaversePluginPermission.notifications => (
      Symbols.notifications_rounded,
      l.metaverse_pluginNotifications,
      l.metaverse_permissionNotificationNote,
    ),
    MetaversePluginPermission.links => (
      Symbols.link_rounded,
      l.metaverse_permissionLinks,
      manifest.linkHosts.join(' · '),
    ),
    MetaversePluginPermission.publicImages => (
      Symbols.image_rounded,
      l.metaverse_permissionImages,
      l.metaverse_pluginPublicImages,
    ),
  };
}

Future<bool> showMetaversePermissionRequest(
  BuildContext context,
  MetaversePluginManifest manifest,
  Set<MetaversePluginPermission> missing,
) async =>
    await AppBottomSheet.show<bool>(
      context: context,
      title: context.l10n.metaverse_requestAccess(manifest.localizedName(context.l10n.localeName)),
      showDragHandle: true,
      builder: (sheet) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedCardGroup(
              children: [
                for (final p in missing)
                  Builder(
                    builder: (context) {
                      final (icon, title, note) = _presentation(
                        context,
                        manifest,
                        p,
                      );
                      return ListTile(
                        leading: Icon(icon, color: context.emphasis.accent),
                        title: Text(title),
                        subtitle: note == null ? null : Text(note),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheet).pop(true),
              child: Text(sheet.l10n.common_allow),
            ),
            TextButton(
              onPressed: () => Navigator.of(sheet).pop(false),
              child: Text(sheet.l10n.common_cancel),
            ),
          ],
        ),
      ),
    ) ??
    false;
