import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/s.dart';
import '../models/user.dart';
import '../pages/bookmarks_page.dart';
import '../pages/browsing_history_page.dart';
import '../pages/chat/chat_list_page.dart';
import '../pages/drafts_page.dart';
import '../pages/private_messages_page.dart';
import '../pages/profile_page.dart';
import '../pages/seeking_page.dart';
import '../pages/topics_screen.dart';
import '../providers/discourse_providers.dart';
import '../providers/chat/chat_channels_provider.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/notification/notification_quick_panel.dart';
import 'nav_action_bus.dart';
import 'nav_entry.dart';

/// 注册所有可选底栏入口
///
/// 用户在底栏布局编辑器里从这些里挑选显示哪些、顺序如何。
/// 增加新入口时在 [buildAll] 里追加一条即可。
class NavEntryRegistry {
  NavEntryRegistry._();

  /// 构建完整候选列表
  static List<NavEntry> buildAll() {
    return [
      NavEntry(
        id: NavEntryIds.home,
        kind: NavEntryKind.page,
        iconData: Symbols.home_rounded,
        selectedIconData: Symbols.home_rounded,
        label: (ctx) => ctx.l10n.nav_home,
        pageBuilder: (ctx, isActive) => TopicsScreen(isActive: isActive),
        locked: true,
        defaultInBottomNav: true,
      ),
      NavEntry(
        id: NavEntryIds.profile,
        kind: NavEntryKind.page,
        iconData: Symbols.person_rounded,
        selectedIconData: Symbols.person_rounded,
        label: (ctx) => ctx.l10n.nav_mine,
        pageBuilder: (ctx, isActive) => ProfilePage(isActive: isActive),
        locked: true,
        defaultInBottomNav: true,
        // 已登录时用用户头像替代默认图标
        customIconBuilder: (ctx, ref) =>
            _profileIcon(ctx, ref, selected: false),
        customSelectedIconBuilder: (ctx, ref) =>
            _profileIcon(ctx, ref, selected: true),
      ),
      NavEntry(
        id: NavEntryIds.bookmarks,
        kind: NavEntryKind.page,
        iconData: Symbols.bookmark_rounded,
        selectedIconData: Symbols.bookmark_rounded,
        label: (ctx) => ctx.l10n.nav_bookmarks,
        pageBuilder: (ctx, isActive) => BookmarksPage(isActive: isActive),
        requiresLogin: true,
      ),
      NavEntry(
        id: NavEntryIds.history,
        kind: NavEntryKind.page,
        iconData: Symbols.history_rounded,
        selectedIconData: Symbols.history_rounded,
        label: (ctx) => ctx.l10n.nav_history,
        pageBuilder: (ctx, isActive) =>
            BrowsingHistoryPage(isActive: isActive),
        requiresLogin: true,
      ),
      NavEntry(
        id: NavEntryIds.drafts,
        kind: NavEntryKind.page,
        iconData: Symbols.drafts_rounded,
        selectedIconData: Symbols.drafts_rounded,
        label: (ctx) => ctx.l10n.nav_drafts,
        pageBuilder: (ctx, isActive) => DraftsPage(isActive: isActive),
        requiresLogin: true,
      ),
      NavEntry(
        id: NavEntryIds.messages,
        kind: NavEntryKind.page,
        iconData: Symbols.mail_rounded,
        selectedIconData: Symbols.mail_rounded,
        label: (ctx) => ctx.l10n.nav_messages,
        pageBuilder: (ctx, isActive) =>
            PrivateMessagesPage(isActive: isActive),
        requiresLogin: true,
      ),
      NavEntry(
        id: NavEntryIds.chat,
        kind: NavEntryKind.page,
        iconData: Symbols.forum_rounded,
        selectedIconData: Symbols.forum_rounded,
        label: (ctx) => ctx.l10n.chat_title,
        pageBuilder: (ctx, isActive) => ChatListPage(isActive: isActive),
        requiresLogin: true,
        // 未读徽章:watch 即激活 chatChannelsProvider(全局非 autoDispose),
        // 使 new-channel/user-tracking-state 订阅随底栏常驻
        customIconBuilder: (ctx, ref) => _chatIcon(ref, selected: false),
        customSelectedIconBuilder: (ctx, ref) => _chatIcon(ref, selected: true),
      ),
      NavEntry(
        id: NavEntryIds.seeking,
        kind: NavEntryKind.page,
        iconData: Symbols.visibility_rounded,
        selectedIconData: Symbols.visibility_rounded,
        label: (ctx) => ctx.l10n.seeking_title,
        pageBuilder: (ctx, isActive) => SeekingPage(isActive: isActive),
        requiresLogin: true,
      ),
      NavEntry(
        id: NavEntryIds.notifications,
        kind: NavEntryKind.panel,
        iconData: Symbols.notifications_rounded,
        selectedIconData: Symbols.notifications_rounded,
        label: (ctx) => ctx.l10n.nav_notifications,
        onPanelTap: (ctx, ref) => NotificationQuickPanel.show(ctx),
        requiresLogin: true,
      ),
    ];
  }

  /// 按 id 查找 entry
  static NavEntry? byId(String id) {
    for (final e in buildAll()) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 根据用户登录状态过滤可用 entry
  static bool isAvailable(NavEntry entry, User? user) {
    if (!entry.requiresLogin) return true;
    return user != null;
  }

  /// 默认底栏 id 列表
  static List<String> defaultBottomNavIds() {
    return buildAll()
        .where((e) => e.defaultInBottomNav)
        .map((e) => e.id)
        .toList();
  }

  /// 必须包含的 locked id 列表
  static List<String> lockedIds() {
    return buildAll().where((e) => e.locked).map((e) => e.id).toList();
  }
}

Widget _chatIcon(WidgetRef ref, {required bool selected}) {
  final unread = ref.watch(chatTotalUnreadProvider);
  final icon = Icon(Symbols.forum_rounded, fill: selected ? 1 : 0);
  if (unread <= 0) return icon;
  return Badge(
    label: Text(unread > 99 ? '99+' : '$unread'),
    child: icon,
  );
}

Widget _profileIcon(
  BuildContext context,
  WidgetRef ref, {
  required bool selected,
}) {
  final user = ref.watch(currentUserProvider).value;
  final avatarUrl = user?.getAvatarUrl();
  final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;
  if (hasAvatar) {
    return SmartAvatar(
      imageUrl: avatarUrl,
      radius: 12,
      fallbackText: user?.username,
    );
  }
  return Icon(Symbols.person_rounded, fill: selected ? 1 : 0);
}
