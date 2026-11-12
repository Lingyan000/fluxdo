import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_checkout_types.dart';
import '../metaverse_plugin_installer.dart';
import 'metaverse_widget_library.dart';

/// 输入清单地址。
typedef PluginInstallChoice = ({String? url, MetaversePluginPackage? bundled});

Future<bool> showMetaverseOrderConfirmation(
  BuildContext context,
  MetaverseCheckoutGrant grant,
  MetaverseOrderIntent intent,
) async {
  final site = Uri.parse(grant.endpoints.create).host;
  return await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.metaverse_checkoutConfirm),
          scrollable: true,
          content: Text(
            ctx.l10n.metaverse_checkoutSummary(
              site,
              grant.displayName ?? grant.subject,
              intent.productId,
              intent.quantity,
              intent.couponClaimId ?? '—',
              '${intent.expectedAmount.toStringAsFixed(2)} ${grant.unit}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.metaverse_checkoutConfirm),
            ),
          ],
        ),
      ) ??
      false;
}

Future<PluginInstallChoice?> showMetaversePluginUrlDialog(
  BuildContext context,
  List<MetaversePluginPackage> bundled,
) {
  var address = '';
  return showAppDialog<PluginInstallChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.metaverse_addService),
      content: TextField(
        onChanged: (value) => address = value,
        autofocus: bundled.isEmpty,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: ctx.l10n.metaverse_pluginManifestUrl,
          hintText: 'https://example.com/plugin.json',
          border: OutlineInputBorder(borderRadius: ctx.shapes.borderRadius(4)),
        ),
        onSubmitted: (value) => Navigator.pop<PluginInstallChoice>(ctx, (
          url: value.trim(),
          bundled: null,
        )),
      ),
      actions: [
        for (final package in bundled)
          TextButton(
            onPressed: () => Navigator.pop<PluginInstallChoice>(ctx, (
              url: null,
              bundled: package,
            )),
            child: Text(package.manifest.name),
          ),
        TextButton(
          onPressed: () => Navigator.pop<PluginInstallChoice>(ctx, (
            url: null,
            bundled: null,
          )),
          child: Text(ctx.l10n.metaverse_importFile),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop<PluginInstallChoice>(ctx, (
            url: address.trim(),
            bundled: null,
          )),
          child: Text(ctx.l10n.common_confirm),
        ),
      ],
    ),
  );
}

/// 安装确认：把清单声明的权限逐条摆给用户看。
///
/// 这里展示的域名与权限来自清单本身，是"运行期无法扩权"这个承诺的对外呈现。
Future<bool> showMetaversePluginInstallSheet(
  BuildContext context,
  MetaversePluginManifest manifest, {
  required bool isUpdate,
}) async {
  final confirmed = await AppBottomSheet.showDraggable<bool>(
    context: context,
    title: manifest.name,
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
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(ctx.l10n.common_cancel),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  icon: Icon(
                    isUpdate
                        ? Symbols.update_rounded
                        : Symbols.download_rounded,
                  ),
                  label: Text(
                    isUpdate
                        ? ctx.l10n.metaverse_pluginUpdate
                        : ctx.l10n.metaverse_pluginInstall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    bodyBuilder: (ctx, controller) =>
        _InstallReview(manifest: manifest, controller: controller),
  );
  return confirmed ?? false;
}

class _InstallReview extends StatelessWidget {
  const _InstallReview({required this.manifest, required this.controller});

  final MetaversePluginManifest manifest;
  final ScrollController controller;

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
        if (manifest.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(manifest.description, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 24),
        Text(l.metaverse_pluginPermissions, style: theme.textTheme.titleSmall),
        const SizedBox(height: 12),
        SegmentedCardGroup(
          children: [
            _PermissionRow(
              icon: Symbols.public_rounded,
              title: l.metaverse_permissionNetwork,
              description: manifest.networkHosts.isEmpty
                  ? l.metaverse_pluginPermNetworkNone
                  : manifest.networkHosts.join(' · '),
            ),
            if (manifest.publicImages)
              _PermissionRow(
                icon: Symbols.image_rounded,
                title: l.metaverse_permissionImages,
                description: l.metaverse_pluginPublicImages,
              ),
            if (manifest.auth.canAttachCredential)
              _PermissionRow(
                icon: Symbols.account_circle_rounded,
                title: l.metaverse_permissionAccount,
                description: manifest.auth.connect != null
                    ? l.metaverse_permissionNativeLogin
                    : manifest.auth.required
                    ? l.metaverse_pluginPermToken
                    : l.metaverse_pluginPermReadSession,
                details: [
                  ...manifest.auth.hosts,
                  if (manifest.auth.connect != null)
                    ...manifest.auth.connect!.values,
                ],
              ),
            if (manifest.auth.queries.isNotEmpty)
              _PermissionRow(
                icon: Symbols.manage_search_rounded,
                title: l.metaverse_permissionQueries,
                description: l.metaverse_permissionQueriesNote,
                details: manifest.auth.queries.values.toList(),
              ),
            if (manifest.auth.checkout case final endpoints?)
              _PermissionRow(
                icon: Symbols.shopping_bag_rounded,
                title: l.metaverse_permissionOrders,
                description: l.metaverse_permissionOrdersNote,
                details: [endpoints.create, endpoints.lookup],
              ),
            if (manifest.auth.payment != null)
              _PermissionRow(
                icon: Symbols.payments_rounded,
                title: l.metaverse_nativePayTitle,
                description: l.metaverse_permissionPaymentNote,
              ),
            if (manifest.webLogin case final Uri login)
              _PermissionRow(
                icon: Symbols.language_rounded,
                title: l.metaverse_permissionWebSession,
                description: l.metaverse_pluginWebSession,
                details: [login.host],
              ),
            if (manifest.linkHosts.isNotEmpty)
              _PermissionRow(
                icon: Symbols.link_rounded,
                title: l.metaverse_permissionLinks,
                description: l.metaverse_pluginPermLinks,
                details: manifest.linkHosts,
              ),
            if (manifest.identity)
              _PermissionRow(
                icon: Symbols.person_rounded,
                title: l.metaverse_pluginPermIdentity,
              ),
          ],
        ),
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

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.icon,
    required this.title,
    this.description,
    this.details = const [],
  });
  final IconData icon;
  final String title;
  final String? description;
  final List<String> details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final leading = Icon(icon, size: 22, color: context.emphasis.accent);
    final subtitle = description == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
    if (details.isEmpty) {
      return ListTile(
        leading: leading,
        title: Text(title),
        subtitle: subtitle,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      );
    }
    return ExpansionTile(
      leading: leading,
      title: Text(title),
      subtitle: subtitle,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final detail in details)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(detail, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// 索取凭证。凭证由宿主保存，脚本只能通过白名单请求间接使用。
Future<String?> showMetaversePluginTokenDialog(
  BuildContext context,
  MetaversePluginManifest manifest,
) {
  final auth = manifest.auth;
  var token = '';
  return showAppDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.metaverse_pluginTokenTitle(manifest.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ctx.l10n.metaverse_pluginTokenNote(auth.hosts.join('、')),
            style: Theme.of(ctx).textTheme.bodySmall
                ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (value) => token = value,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: auth.label ?? ctx.l10n.metaverse_pluginTokenLabel,
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
      content: Text(ctx.l10n.metaverse_pluginRemoveConfirm(manifest.name)),
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
