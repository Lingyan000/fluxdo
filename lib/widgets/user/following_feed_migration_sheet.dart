import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../pages/user_profile_page.dart';
import '../common/app_bottom_sheet.dart';
import '../common/smart_avatar.dart';

/// 首次进入动态时说明功能调整，返回是否立即查看旧名单。
Future<bool?> showFollowingFeedMigrationSheet(
  BuildContext context, {
  required bool hasLegacyUsers,
}) => AppBottomSheet.show<bool>(
  context: context,
  title: context.l10n.followingFeed_migrationTitle,
  footer: Builder(
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.followingFeed_migrationContinue),
          ),
          if (hasLegacyUsers) ...[
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.l10n.followingFeed_viewLegacyUsers),
            ),
          ],
        ],
      ),
    ),
  ),
  contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
  builder: (context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.followingFeed_migrationSummary,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.followingFeed_migrationChanges,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (hasLegacyUsers) ...[
            const SizedBox(height: 16),
            Text(context.l10n.followingFeed_migrationListHint),
          ],
        ],
      ),
    );
  },
);

/// 本机旧名单可从引导或自己的关注列表查看，选中后进入用户主页。
Future<void> showFollowingFeedLegacyUsers(
  BuildContext context,
  List<String> users,
) async {
  final username = await AppBottomSheet.show<String>(
    context: context,
    title: context.l10n.followingFeed_legacyUsers,
    builder: (context) => ListView.builder(
      shrinkWrap: true,
      itemCount: users.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            child: Text(
              context.l10n.followingFeed_legacyHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final username = users[index - 1];
        return ListTile(
          leading: SmartAvatar(radius: 20, fallbackText: username),
          title: Text(username),
          trailing: const Icon(Symbols.chevron_right_rounded),
          onTap: () => Navigator.of(context).pop(username),
        );
      },
    ),
  );
  if (username != null && context.mounted) {
    await Navigator.of(context).push(
      InteractionPageRoute(builder: (_) => UserProfilePage(username: username)),
    );
  }
}
