import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/s.dart';
import '../../../../services/toast_service.dart';
import '../../../../utils/dialog_utils.dart';
import '../../../../utils/link_launcher.dart';
import '../../../../widgets/common/app_bottom_sheet.dart';
import '../metaverse_plugin_manifest.dart';
import '../metaverse_checkout_types.dart';
import '../metaverse_plugin_installer.dart';
import 'metaverse_plugin_surface_view.dart';

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
  final confirmed = await AppBottomSheet.show<bool>(
    context: context,
    title: isUpdate
        ? context.l10n.metaverse_pluginUpdate
        : context.l10n.metaverse_pluginInstall,
    builder: (ctx) => _InstallReview(manifest: manifest),
  );
  return confirmed ?? false;
}

class _InstallReview extends StatelessWidget {
  const _InstallReview({required this.manifest});

  final MetaversePluginManifest manifest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linkHosts = manifest.linkHosts;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                manifest.description.isEmpty
                    ? manifest.name
                    : manifest.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Section(
          icon: Symbols.public_rounded,
          title: context.l10n.metaverse_pluginPermissions,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (manifest.networkHosts.isEmpty)
                _Bullet(context.l10n.metaverse_pluginPermNetworkNone)
              else ...[
                _Bullet(context.l10n.metaverse_pluginPermNetwork),
                const SizedBox(height: 6),
                MetaverseHostList(hosts: manifest.networkHosts),
              ],
              if (manifest.publicImages)
                _Bullet(context.l10n.metaverse_pluginPublicImages),
              if (manifest.webLogin case final Uri login) ...[
                _Bullet(context.l10n.metaverse_pluginWebSession),
                MetaverseHostList(hosts: [login.host]),
              ],
              if (linkHosts.isNotEmpty) ...[
                const SizedBox(height: 10),
                _Bullet(context.l10n.metaverse_pluginPermLinks),
                const SizedBox(height: 6),
                MetaverseHostList(hosts: linkHosts),
              ],
              if (manifest.identity) ...[
                const SizedBox(height: 10),
                _Bullet(context.l10n.metaverse_pluginPermIdentity),
              ],
              if (manifest.auth.canAttachCredential) ...[
                const SizedBox(height: 10),
                _Bullet(
                  manifest.auth.required
                      ? context.l10n.metaverse_pluginPermToken
                      : context.l10n.metaverse_pluginPermReadSession,
                ),
                const SizedBox(height: 6),
                MetaverseHostList(hosts: manifest.auth.hosts),
                if (manifest.auth.connect != null ||
                    manifest.auth.payment != null)
                  _Bullet(context.l10n.metaverse_nativeLoginAccess),
                if (manifest.auth.queries.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _Bullet(context.l10n.metaverse_pluginPermQueries),
                  for (final url in manifest.auth.queries.values) Text(url),
                ],
                if (manifest.auth.checkout case final endpoints?) ...[
                  _Bullet(context.l10n.metaverse_checkoutPermission),
                  Text(endpoints.create),
                  Text(endpoints.lookup),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          context.l10n.metaverse_pluginWarning,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              context.l10n.metaverse_pluginAuthor(
                manifest.author,
                manifest.version,
              ),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const Spacer(),
            if (manifest.homepage case final String homepage)
              TextButton.icon(
                onPressed: () => launchExternalLink(context, homepage),
                icon: const Icon(Symbols.open_in_new_rounded, size: 16),
                label: Text(context.l10n.metaverse_pluginSource),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.common_cancel),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.metaverse_pluginInstall),
            ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(16),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodyMedium);
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
