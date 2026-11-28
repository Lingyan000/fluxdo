import 'metaverse_expansion_tile.dart';
import 'package:app_icons/app_icons.dart';
import '../metaverse_plugin_permission.dart';
import '../metaverse_plugin_store.dart';
import 'metaverse_permission_list.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_plugin_installer.dart';
import '../metaverse_approval_change.dart';
import 'metaverse_widget_library.dart';

/// 输入清单地址。
typedef PluginInstallChoice = ({String? url});

Future<PluginInstallChoice?> showMetaversePluginPicker(
  BuildContext context,
) => AppBottomSheet.show<PluginInstallChoice>(
  context: context,
  title: context.l10n.metaverse_addService,
  showCloseButton: true,
  showDragHandle: true,
  builder: (ctx) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SegmentedCardGroup(
        children: [
          ListTile(
            leading: Icon(Symbols.link_rounded, color: ctx.emphasis.accent),
            title: Text(ctx.l10n.metaverse_installFromUrl),
            trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
            onTap: () async {
              final address = await showAppDialog<String>(
                context: ctx,
                builder: (_) => const _PluginUrlInput(),
              );
              if (address != null && ctx.mounted) {
                Navigator.of(ctx)
                    .pop<PluginInstallChoice>((url: address));
              }
            },
          ),
          ListTile(
            leading: Icon(
              Symbols.file_open_rounded,
              color: ctx.emphasis.accent,
            ),
            title: Text(ctx.l10n.metaverse_importFile),
            trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
            onTap: () =>
                Navigator.of(ctx)
                    .pop<PluginInstallChoice>((url: null)),
          ),
        ],
      ),
    ],
  ),
);

class _PluginUrlInput extends StatefulWidget {
  const _PluginUrlInput();
  @override
  State<_PluginUrlInput> createState() => _PluginUrlInputState();
}

class _PluginUrlInputState extends State<_PluginUrlInput> {
  final _controller = TextEditingController();

  bool get _valid {
    final uri = Uri.tryParse(_controller.text.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_valid) Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.metaverse_installFromUrl),
    scrollable: true,
    content: TextField(
      controller: _controller,
      autofocus: true,
      autocorrect: false,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: context.l10n.metaverse_pluginManifestUrl,
        hintText: 'https://example.com/plugin.json',
        errorText: _controller.text.isNotEmpty && !_valid
            ? context.l10n.metaverse_pluginInvalidUrl
            : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.common_cancel),
      ),
      FilledButton(
        onPressed: _valid ? _submit : null,
        child: Text(context.l10n.common_continue),
      ),
    ],
  );
}

/// 返回用户本次调整的开关；取消返回 null。
Future<Map<MetaversePluginPermission, bool>?> showMetaversePluginInstallSheet(
  BuildContext context,
  MetaversePluginManifest manifest, {
  required bool isUpdate,
  String? confirmLabel,
  String? notice,
  MetaversePluginPackage? package,
  InstalledMetaversePlugin? previous,
  InstalledMetaversePlugin? restoredRelease,
  Set<MetaversePluginPermission>? initialBlocked,
}) {
  final initial = initialBlocked ?? InstalledMetaversePlugin.reviewPermissions(manifest, null);
  final choices = <MetaversePluginPermission, bool>{};
  final fingerprint = package != null
      ? package.signature?.fingerprint : restoredRelease?.publisherKey;
  final publisherChanged = previous?.publisherKey != null &&
      (package != null || restoredRelease != null) &&
      fingerprint != previous!.publisherKey &&
      (package == null || package.signature?.previousFingerprint != previous.publisherKey);
  return AppBottomSheet.showDraggable<Map<MetaversePluginPermission, bool>>(
    context: context,
    title: manifest.localizedName(context.l10n.localeName),
    showCloseButton: true,
    initialSize: .82,
    minSize: .45,
    maxSize: .95,
    footer: Builder(
      builder: (ctx) => PageBackdrop(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(ctx.l10n.common_cancel),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(Map.of(choices)),
                  icon: Icon(
                    isUpdate
                        ? Symbols.update_rounded
                        : Symbols.download_rounded,
                  ),
                  label: Text(
                    confirmLabel ?? (isUpdate
                        ? ctx.l10n.metaverse_pluginUpdate
                        : ctx.l10n.metaverse_pluginInstall),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    bodyBuilder: (ctx, controller) => StatefulBuilder(
      builder: (_, update) => _InstallReview(
        manifest: manifest,
        notice: notice,
        publisherKnown: package != null || restoredRelease != null,
        fingerprint: fingerprint,
        publisherWarning: publisherChanged
            ? (restoredRelease == null ? ctx.l10n.metaverse_publisherChanged
                : ctx.l10n.metaverse_publisherRollbackChanged) : null,
        changes: previous == null ? const []
            : _approvalLabels(ctx, manifest.expandedApprovalFrom(previous.manifest)),
        controller: controller,
        blocked: manifest.applyPermissionChoices(initial, choices),
        onChanged: (permission, allowed) => update(() {
          final initiallyAllowed = !initial.contains(permission);
          if (allowed == initiallyAllowed) {
            choices.remove(permission);
          } else {
            choices[permission] = allowed;
          }
        }),
      ),
    ),
  );
}

class _InstallReview extends StatelessWidget {
  const _InstallReview({
    required this.manifest,
    required this.controller,
    required this.blocked,
    required this.onChanged,
    this.notice,
    required this.publisherKnown,
    this.fingerprint,
    this.publisherWarning,
    required this.changes,
  });
  final Set<MetaversePluginPermission> blocked;
  final void Function(MetaversePluginPermission, bool) onChanged;

  final MetaversePluginManifest manifest;
  final ScrollController controller;
  final String? notice, fingerprint, publisherWarning;
  final bool publisherKnown;
  final List<String> changes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l10n;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      children: [
        Row(
          children: [
            Icon(
              metaversePluginIcon(manifest.icon),
              size: 32,
              color: context.emphasis.accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l.metaverse_pluginAuthor(manifest.author, manifest.version),
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (manifest.homepage case final String homepage)
              IconButton(
                tooltip: l.metaverse_pluginSource,
                onPressed: () => launchExternalLink(context, homepage),
                icon: const Icon(Symbols.open_in_new_rounded),
              ),
          ],
        ),
        if (manifest.localizedDescription(context.l10n.localeName).isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(manifest.localizedDescription(context.l10n.localeName), style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 24),
        if (publisherWarning case final warning?) ...[
          _ReviewNotice(
            title: l.metaverse_publisherChangedTitle, message: warning,
            icon: Symbols.warning_rounded, color: theme.colorScheme.errorContainer,
            foreground: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(height: 12),
        ],
        if (changes.isNotEmpty) ...[
          _ReviewNotice(
            title: l.metaverse_updateChanges, message: changes.join(' · '),
            icon: Symbols.security_rounded, color: theme.colorScheme.secondaryContainer,
            foreground: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(height: 12),
        ],
        if (notice?.isNotEmpty == true || publisherKnown) ...[
          SegmentedCardGroup(
            color: PageBackgroundScope.contentColor(context, theme.colorScheme.surfaceContainerLow),
            children: [
              if (notice?.isNotEmpty == true)
                ListTile(leading: const Icon(Symbols.info_rounded), title: Text(notice!)),
              if (publisherKnown && fingerprint == null)
                ListTile(leading: const Icon(Symbols.info_rounded),
                  title: Text(l.metaverse_publisherUnsignedTitle),
                  subtitle: Text(l.metaverse_publisherUnsigned)),
              if (fingerprint case final fp?)
                MetaverseExpansionTile(
                  leading: const Icon(Symbols.key_rounded),
                  title: Text(l.metaverse_publisherKey),
                  subtitle: Text(fp.length > 8 ? '${fp.substring(0, 4)}…${fp.substring(fp.length - 4)}' : fp),
                  children: [Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SelectableText(fp, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Text(l.metaverse_signatureMeaning, style: theme.textTheme.bodySmall),
                    ]))],
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        MetaversePermissionList(manifest: manifest, blocked: blocked, onChanged: onChanged),
        const SizedBox(height: 20),
        Text(
          l.metaverse_pluginWarning,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ReviewNotice extends StatelessWidget {
  const _ReviewNotice({required this.title, required this.message,
    required this.icon, required this.color, required this.foreground});
  final String title, message;
  final IconData icon;
  final Color color, foreground;

  @override
  Widget build(BuildContext context) => SegmentedCardGroup(color: color, children: [
    ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      titleAlignment: ListTileTitleAlignment.top,
      leading: Icon(icon, color: foreground),
      title: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: foreground)),
      subtitle: Padding(padding: const EdgeInsets.only(top: 4),
        child: Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: foreground))),
    ),
  ]);
}

/// 索取凭证。凭证由宿主保存，脚本只能通过白名单请求间接使用。
Future<String?> showMetaversePluginTokenDialog(
  BuildContext context,
  MetaversePluginManifest manifest, {
  String? label,
  List<String>? hosts,
}) {
  final auth = manifest.auth;
  var token = '';
  return showAppDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.metaverse_pluginTokenTitle(manifest.localizedName(context.l10n.localeName))),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ctx.l10n.metaverse_pluginTokenNote((hosts ?? auth.hosts).join('、')),
            style: Theme.of(ctx).textTheme.bodySmall
                ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (value) => token = value,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: label ?? auth.label ?? ctx.l10n.metaverse_pluginTokenLabel,
              border: OutlineInputBorder(
                borderRadius: ctx.shapes.borderRadius(4),
              ),
              isDense: true,
            ),
          ),
          if (auth.helpUrl case final String helpUrl)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                onTap: () => launchExternalLink(ctx, helpUrl),
                child: Text(
                  ctx.l10n.metaverse_pluginTokenHelp,
                  style: Theme.of(ctx).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(ctx).colorScheme.primary),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, token),
          child: Text(ctx.l10n.common_confirm),
        ),
      ],
    ),
  );
}

/// 移除插件前的确认。
Future<bool> showMetaversePluginRemoveDialog(
  BuildContext context,
  MetaversePluginManifest manifest,
) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.common_remove),
      content: Text(ctx.l10n.metaverse_pluginRemoveConfirm(manifest.localizedName(context.l10n.localeName))),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ctx.l10n.common_remove),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// 插件发起的提示：带上来源，用户能分辨它不是应用自己说的。
void showMetaversePluginToast(String pluginName, String message, String type) {
  final text = S.current.metaverse_pluginToast(pluginName, message);
  switch (type) {
    case 'success':
      ToastService.showSuccess(text);
    case 'error':
      ToastService.showError(text);
    case _:
      ToastService.showInfo(text);
  }
}

List<String> _approvalLabels(BuildContext context, List<String> changes) {
  final l = context.l10n;
  return changes.map((change) => switch (change.split('.').first) {
    'storage' => l.metaverse_pluginData,
    'network' => l.metaverse_permissionNetwork,
    'identity' => l.metaverse_permissionIdentity,
    'publicImages' => l.metaverse_permissionImages,
    'credentials' || 'connect' || 'webLogin' || 'auth' => l.metaverse_permissionAccount,
    'payments' => l.metaverse_nativePayTitle,
    'forum' => l.metaverse_forumActivity,
    'background' => l.metaverse_backgroundTasks,
    'notifications' => l.metaverse_pluginNotifications,
    'tasks' => l.metaverse_foregroundTasks,
    'links' => l.metaverse_permissionLinks,
    _ => l.metaverse_permissionScopes,
  }).toSet().toList();
}
