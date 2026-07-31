import 'package:flutter_test/flutter_test.dart';

import 'package:fluxdo/services/data_management/data_backup_service.dart';

void main() {
  group('DataBackupService v2 反白名单', () {
    test('用户配置默认纳入(v1 白名单时代的漏备项)', () {
      const keys = [
        // v1 前缀白名单能覆盖的
        'pref_locale',
        'theme_mode',
        'seed_color',
        'read_later_items',
        // v1 漏备的重灾区(审计实锤)
        'font_family',
        'scheme_variant',
        'custom_colors',
        'web_bookmarks',
        'recent_emojis',
        'sticker_subscribed_groups',
        'sticker_recent_items',
        'upstream_proxy_protocol',
        'upstream_proxy_cipher',
        'shortcuts_custom',
        'profile_stats_config',
        'topic_new_subset',
        'auto_check_update',
        'notion_config_alice',
        'rhttp_enabled',
        'cdk_enabled',
        'ldc_enabled',
        // 被排除前缀误伤的真配置,精确回捞
        'sticker_market_base_url',
      ];
      for (final key in keys) {
        expect(
          DataBackupService.debugShouldBackup(key),
          isTrue,
          reason: '$key 应被备份',
        );
      }
    });

    test('缓存/会话/设备态/一次性标记被排除', () {
      const keys = [
        // 缓存/派生
        'ai_chat_session_messages_123',
        'ai_post_review_guidelines_cache',
        'current_user_cache',
        'current_user_cache_username',
        'user_summary_cache',
        'cdk_user_info',
        'ldc_user_info_username',
        'update_cache',
        'update_etag',
        'sticker_market_groups_cache',
        'bookmark_last_full_sync_42',
        'blob_image_cache_last_sweep',
        // 会话/凭证
        'linux_do_csrf_token',
        'linux_do_username',
        'auth_passive_logout_history_v1',
        'bg_shared_session_key',
        'one_time_password',
        // 设备/运行态
        'cronet_has_fallen_back',
        'vpn_suppressed_doh',
        'per_device_cert_installed',
        'cert_use_per_device',
        'window_x',
        // 一次性标记
        'onboarding_completed',
        'crashlytics_notice_shown',
        'ai_chat_guide_shown',
        'profile_stats_card_guide_shown',
        'cursor_swipe_hint_move_left',
        // 迁移标记(动态派生自 MigrationService)
        'image_cache_orphan_purge_v7',
        'emoji_blob_cache_v8',
        'cookie_clean_slate_v2',
        'cookie_domain_migration_v2',
      ];
      for (final key in keys) {
        expect(
          DataBackupService.debugShouldBackup(key),
          isFalse,
          reason: '$key 不应被备份',
        );
      }
    });
  });
}
