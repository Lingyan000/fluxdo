import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme_provider.dart';

/// 旧名单只用于迁移引导，不恢复监控，也不自动建立关注关系。
class FollowingFeedMigration {
  const FollowingFeedMigration({
    required this.usedSeeking,
    required this.users,
    required this.dismissed,
  });
  final bool usedSeeking;
  final List<String> users;
  final bool dismissed;
  bool get showGuide => usedSeeking && !dismissed;

  factory FollowingFeedMigration.read(SharedPreferences prefs) {
    var users = <String>[];
    final raw = prefs.getString('seeking_config');
    try {
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        users = (data['users'] as List? ?? [])
            .whereType<String>()
            .where((name) => name.trim().isNotEmpty)
            .toSet()
            .toList();
      }
    } catch (_) {
      // 损坏的旧配置不应阻止进入动态页。
    }
    return FollowingFeedMigration(
      usedSeeking:
          raw != null ||
          prefs.getBool('seeking_enabled') == true ||
          (prefs.getStringList('pref_bottom_nav_ids') ?? []).contains(
            'seeking',
          ),
      users: users,
      dismissed: prefs.getBool('following_feed_migration_seen') ?? false,
    );
  }
}

class FollowingFeedMigrationNotifier
    extends StateNotifier<FollowingFeedMigration> {
  FollowingFeedMigrationNotifier(this.prefs)
    : super(FollowingFeedMigration.read(prefs));
  final SharedPreferences prefs;
  Future<void> dismiss() async {
    await prefs.setBool('following_feed_migration_seen', true);
    if (mounted) state = FollowingFeedMigration.read(prefs);
  }
}

final followingFeedMigrationProvider =
    StateNotifierProvider<
      FollowingFeedMigrationNotifier,
      FollowingFeedMigration
    >(
      (ref) =>
          FollowingFeedMigrationNotifier(ref.watch(sharedPreferencesProvider)),
    );
