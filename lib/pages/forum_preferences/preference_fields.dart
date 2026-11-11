import 'package:timezone/timezone.dart' as tz;

import '../../l10n/s.dart';
import '../../models/forum_preferences.dart';

String preferenceSectionLabel(
  ForumPreferenceSection section,
  AppLocalizations l,
) => switch (section) {
  ForumPreferenceSection.account => l.forumPrefs_account,
  ForumPreferenceSection.security => l.forumPrefs_security,
  ForumPreferenceSection.profile => l.forumPrefs_profile,
  ForumPreferenceSection.notifications => l.forumPrefs_notifications,
  ForumPreferenceSection.emails => l.forumPrefs_emails,
  ForumPreferenceSection.tracking => l.forumPrefs_tracking,
  ForumPreferenceSection.users => l.forumPrefs_users,
  ForumPreferenceSection.interface => l.forumPrefs_interface,
  ForumPreferenceSection.navigation => l.forumPrefs_navigation,
  ForumPreferenceSection.chat => l.forumPrefs_chat,
  ForumPreferenceSection.apps => l.forumPrefs_apps,
  ForumPreferenceSection.calendar => l.forumPrefs_calendar,
};

List<ForumPreferenceField> preferenceFields(
  ForumPreferenceSection section,
  ForumPreferences data,
  AppLocalizations l,
) {
  final result = <ForumPreferenceField>[];
  final user = data.user;
  final settings = data.settings;
  final options = data.options;
  void option(
    String key,
    String label, {
    ForumPreferenceKind kind = ForumPreferenceKind.toggle,
    Map<Object, String> choices = const {},
    String? help,
  }) {
    if (options.containsKey(key)) {
      result.add(
        ForumPreferenceField(
          key: key,
          label: label,
          container: 'user_option',
          kind: kind,
          choices: choices,
          help: help,
        ),
      );
    }
  }

  void field(
    String key,
    String label, {
    ForumPreferenceKind kind = ForumPreferenceKind.text,
    Map<Object, String> choices = const {},
    String? help,
    String? permission,
    String? uploadType,
    Object? emptyValue,
  }) {
    if (permission != null && user[permission] != true) return;
    result.add(
      ForumPreferenceField(
        key: key,
        label: label,
        kind: kind,
        choices: choices,
        help: help,
        uploadType: uploadType,
        emptyValue: emptyValue,
      ),
    );
  }

  Map<Object, String> records(String key, {String id = 'id'}) => {
    for (final item in (data.site[key] as List? ?? []).whereType<Map>())
      if (item[id] != null) item[id] as Object: '${item['name'] ?? item[id]}',
  };
  final emailLevels = {
    0: l.forumPrefs_always,
    1: l.forumPrefs_whenAway,
    2: l.forumPrefs_never,
  };
  final groups = {
    0: l.forumPrefs_none,
    for (final group in data.records('groups'))
      group['id'] as Object: '${group['name']}',
  };
  switch (section) {
    case ForumPreferenceSection.account:
      if (settings['enable_names'] != false) {
        field('name', l.forumPrefs_name, permission: 'can_edit_name');
      }

      if (settings['user_selected_primary_groups'] == true &&
          groups.length > 1) {
        field(
          'primary_group_id',
          l.forumPrefs_primaryGroup,
          kind: ForumPreferenceKind.choice,
          choices: groups,
        );
      }
      field(
        'flair_group_id',
        l.forumPrefs_flairGroup,
        kind: ForumPreferenceKind.choice,
        choices: {
          0: l.forumPrefs_none,
          for (final group
              in data
                  .records('groups')
                  .where((group) => group['flair_url'] != null))
            group['id'] as Object: '${group['name']}',
        },
      );
    case ForumPreferenceSection.profile:
      field(
        'bio_raw',
        l.forumPrefs_bio,
        kind: ForumPreferenceKind.multiline,
        permission: 'can_change_bio',
      );
      field(
        'location',
        l.forumPrefs_location,
        permission: 'can_change_location',
      );
      field('website', l.forumPrefs_website, permission: 'can_change_website');
      if (user.containsKey('date_of_birth')) {
        field(
          'date_of_birth',
          l.forumPrefs_birthday,
          help: l.forumPrefs_birthdayHint,
        );
      }
      field(
        'profile_background_upload_url',
        l.forumPrefs_profileBackground,
        kind: ForumPreferenceKind.image,
        permission: 'can_upload_profile_header',
        uploadType: 'profile_background',
      );
      field(
        'card_background_upload_url',
        l.forumPrefs_cardBackground,
        kind: ForumPreferenceKind.image,
        permission: 'can_upload_user_card_background',
        uploadType: 'card_background',
      );
      option(
        'timezone',
        l.forumPrefs_timezone,
        kind: ForumPreferenceKind.choice,
        choices: {
          for (final zone in tz.timeZoneDatabase.locations.keys) zone: zone,
        },
      );
      option('hide_profile', l.forumPrefs_hideProfile);
      if (options['default_calendar'] != 'none_selected') {
        option(
          'default_calendar',
          l.forumPrefs_calendarApp,
          kind: ForumPreferenceKind.choice,
          choices: {
            'ics': 'ICS',
            'google': 'Google Calendar',
            'none_selected': l.forumPrefs_none,
          },
        );
      }
      final customFields =
          (data.site['user_fields'] as List? ?? []).whereType<Map>().toList()
            ..sort(
              (a, b) => ((a['position'] as num?) ?? 0).compareTo(
                (b['position'] as num?) ?? 0,
              ),
            );
      for (final custom in customFields) {
        if (custom['editable'] != true &&
            user['admin'] != true &&
            user['moderator'] != true) {
          continue;
        }
        final type = custom['field_type'];
        final previous = (user['user_fields'] as Map?)?['${custom['id']}'];
        final required =
            custom['requirement'] == 'for_all_users' ||
            (custom['requirement'] == 'on_signup' &&
                previous != null &&
                previous != '');
        result.add(
          ForumPreferenceField(
            key: '${custom['id']}',
            label: '${custom['name']}',
            container: 'user_fields',
            kind: switch (type) {
              'confirm' => ForumPreferenceKind.toggle,
              'dropdown' => ForumPreferenceKind.choice,
              'multiselect' => ForumPreferenceKind.multiChoice,
              _ => ForumPreferenceKind.text,
            },
            choices: {
              if (type == 'dropdown' && !required) '': l.forumPrefs_none,
              for (final value in custom['options'] as List? ?? [])
                value as Object: '$value',
            },
            required: required,
          ),
        );
      }
    case ForumPreferenceSection.notifications:
      option(
        'like_notification_frequency',
        l.forumPrefs_likeFrequency,
        kind: ForumPreferenceKind.choice,
        choices: {
          0: l.forumPrefs_always,
          1: l.forumPrefs_firstDaily,
          2: l.forumPrefs_firstOnly,
          3: l.forumPrefs_never,
        },
      );
      option('notify_on_linked_posts', l.forumPrefs_linkedPosts);
      if (user['user_notification_schedule'] is Map) {
        field(
          'user_notification_schedule',
          l.forumPrefs_schedule,
          kind: ForumPreferenceKind.schedule,
          help: l.forumPrefs_scheduleHelp,
        );
      }
    case ForumPreferenceSection.emails:
      option(
        'email_level',
        l.forumPrefs_emailLevel,
        kind: ForumPreferenceKind.choice,
        choices: emailLevels,
      );
      option(
        'email_messages_level',
        l.forumPrefs_emailMessages,
        kind: ForumPreferenceKind.choice,
        choices: emailLevels,
      );
      option(
        'email_previous_replies',
        l.forumPrefs_emailReplies,
        kind: ForumPreferenceKind.choice,
        choices: {
          0: l.forumPrefs_always,
          1: l.forumPrefs_unlessEmailed,
          2: l.forumPrefs_never,
        },
      );
      option('email_in_reply_to', l.forumPrefs_emailInReplyTo);
      option('email_digests', l.forumPrefs_emailDigests);
      option(
        'digest_after_minutes',
        l.forumPrefs_digestFrequency,
        kind: ForumPreferenceKind.choice,
        choices: {
          30: l.forumPrefs_minutes30,
          60: l.forumPrefs_hour1,
          1440: l.forumPrefs_day1,
          10080: l.forumPrefs_week1,
          43200: l.forumPrefs_month1,
          259200: l.forumPrefs_months6,
        },
      );
      option('include_tl0_in_digests', l.forumPrefs_includeNewUsers);
      if (settings['disable_mailing_list_mode'] != true) {
        option('mailing_list_mode', l.forumPrefs_mailingList);
        option(
          'mailing_list_mode_frequency',
          l.forumPrefs_mailingFrequency,
          kind: ForumPreferenceKind.choice,
          choices: {1: l.forumPrefs_allPosts, 2: l.forumPrefs_exceptOwn},
        );
      }
      option(
        'chat_email_frequency',
        l.forumPrefs_chatEmail,
        kind: ForumPreferenceKind.choice,
        choices: {
          'never': l.forumPrefs_never,
          'when_away': l.forumPrefs_whenAway,
        },
      );
    case ForumPreferenceSection.tracking:
      if (user['can_change_tracking_preferences'] != true) break;
      option(
        'new_topic_duration_minutes',
        l.forumPrefs_newTopic,
        kind: ForumPreferenceKind.choice,
        choices: {
          -1: l.forumPrefs_notViewed,
          1440: l.forumPrefs_day1,
          2880: l.forumPrefs_days2,
          10080: l.forumPrefs_week1,
          20160: l.forumPrefs_weeks2,
          -2: l.forumPrefs_sinceVisit,
        },
      );
      option(
        'auto_track_topics_after_msecs',
        l.forumPrefs_autoTrack,
        kind: ForumPreferenceKind.choice,
        choices: {
          -1: l.forumPrefs_never,
          0: l.forumPrefs_immediately,
          30000: l.forumPrefs_seconds30,
          60000: l.forumPrefs_minute1,
          120000: l.forumPrefs_minutes2,
          180000: l.forumPrefs_minutes3,
          240000: l.forumPrefs_minutes4,
          300000: l.forumPrefs_minutes5,
          600000: l.forumPrefs_minutes10,
        },
      );
      option(
        'notification_level_when_replying',
        l.forumPrefs_whenReply,
        kind: ForumPreferenceKind.choice,
        choices: {
          3: l.forumPrefs_watching,
          2: l.forumPrefs_trackingLevel,
          1: l.forumPrefs_regular,
        },
      );
      field(
        'watched_category_ids',
        l.forumPrefs_watchedCategories,
        kind: ForumPreferenceKind.categories,
        emptyValue: const [-1],
      );
      field(
        'tracked_category_ids',
        l.forumPrefs_trackedCategories,
        kind: ForumPreferenceKind.categories,
        emptyValue: const [-1],
      );
      field(
        'watched_first_post_category_ids',
        l.forumPrefs_firstCategories,
        kind: ForumPreferenceKind.categories,
        emptyValue: const [-1],
      );
      if (settings['mute_all_categories_by_default'] == true) {
        field(
          'regular_category_ids',
          l.forumPrefs_regularCategories,
          kind: ForumPreferenceKind.categories,
          emptyValue: const [-1],
        );
      } else {
        field(
          'muted_category_ids',
          l.forumPrefs_mutedCategories,
          kind: ForumPreferenceKind.categories,
          emptyValue: const [-1],
        );
      }
      if (settings['tagging_enabled'] == true) {
        field(
          'watched_tags',
          l.forumPrefs_watchedTags,
          kind: ForumPreferenceKind.tags,
        );
        field(
          'tracked_tags',
          l.forumPrefs_trackedTags,
          kind: ForumPreferenceKind.tags,
        );
        field(
          'watching_first_post_tags',
          l.forumPrefs_firstTags,
          kind: ForumPreferenceKind.tags,
        );
        field(
          'muted_tags',
          l.forumPrefs_mutedTags,
          kind: ForumPreferenceKind.tags,
        );
      }
      option('watched_precedence_over_muted', l.forumPrefs_watchPrecedence);
      option('topics_unread_when_closed', l.forumPrefs_unreadClosed);
    case ForumPreferenceSection.users:
      option('allow_private_messages', l.forumPrefs_allowMessages);
      option('enable_allowed_pm_users', l.forumPrefs_onlyAllowed);
      field(
        'allowed_pm_usernames',
        l.forumPrefs_allowedUsers,
        kind: ForumPreferenceKind.usernames,
        help: l.forumPrefs_usernamesHelp,
      );
      field(
        'muted_usernames',
        l.forumPrefs_mutedUsers,
        kind: ForumPreferenceKind.usernames,
        permission: 'can_mute_users',
        help: l.forumPrefs_usernamesHelp,
      );
    case ForumPreferenceSection.interface:
      if (settings['allow_user_locale'] == true) {
        final locales = settings['available_locales'] as List? ?? [];
        field(
          'locale',
          l.forumPrefs_locale,
          kind: ForumPreferenceKind.choice,
          choices: {
            '': l.forumPrefs_defaultValue,
            for (final locale in locales.whereType<Map>())
              locale['value'] as Object:
                  '${locale['nativeName'] ?? locale['name']}',
          },
        );
      }
      option('external_links_in_new_tab', l.forumPrefs_externalLinks);
      option('dynamic_favicon', l.forumPrefs_dynamicFavicon);
      option('enable_quoting', l.forumPrefs_quoting);
      option('enable_smart_lists', l.forumPrefs_smartLists);
      option('enable_defer', l.forumPrefs_defer);
      option('automatically_unpin_topics', l.forumPrefs_unpin);
      option('enable_markdown_monospace_font', l.forumPrefs_monospace);
      option('show_original_content', l.forumPrefs_originalContent);
      option('hide_presence', l.forumPrefs_hidePresence);
      option('skip_new_user_tips', l.forumPrefs_hideTips);
      option(
        'homepage_id',
        l.forumPrefs_homepage,
        kind: ForumPreferenceKind.choice,
        choices: {
          1: l.forumPrefs_latest,
          2: l.forumPrefs_categories,
          3: l.forumPrefs_unread,
          4: l.forumPrefs_newTopics,
          5: l.forumPrefs_top,
          6: l.forumPrefs_bookmarks,
          7: l.forumPrefs_unseen,
          8: l.forumPrefs_hot,
        },
      );
      option(
        'text_size',
        l.forumPrefs_textSize,
        kind: ForumPreferenceKind.choice,
        choices: {
          'smallest': l.forumPrefs_smallest,
          'smaller': l.forumPrefs_smaller,
          'normal': l.forumPrefs_normal,
          'larger': l.forumPrefs_larger,
          'largest': l.forumPrefs_largest,
        },
      );
      option(
        'title_count_mode',
        l.forumPrefs_countMode,
        kind: ForumPreferenceKind.choice,
        choices: {
          'notifications': l.forumPrefs_notifications,
          'contextual': l.forumPrefs_contextual,
        },
      );
      option(
        'bookmark_auto_delete_preference',
        l.forumPrefs_bookmarkDelete,
        kind: ForumPreferenceKind.choice,
        choices: {
          0: l.forumPrefs_never,
          1: l.forumPrefs_afterReminder,
          2: l.forumPrefs_afterOwnerReply,
          3: l.forumPrefs_clearReminder,
        },
      );
      option(
        'interface_color_mode',
        l.forumPrefs_colorMode,
        kind: ForumPreferenceKind.choice,
        choices: {
          1: l.forumPrefs_system,
          2: l.forumPrefs_light,
          3: l.forumPrefs_dark,
        },
      );
      final themes = records('user_themes', id: 'theme_id');
      if (themes.isNotEmpty) {
        option(
          'theme_ids',
          l.forumPrefs_theme,
          kind: ForumPreferenceKind.theme,
          choices: themes,
        );
      }
      final schemes = records('user_color_schemes');
      if (schemes.isNotEmpty) {
        option(
          'color_scheme_id',
          l.forumPrefs_lightScheme,
          kind: ForumPreferenceKind.choice,
          choices: {-1: l.forumPrefs_defaultValue, ...schemes},
        );
        option(
          'dark_scheme_id',
          l.forumPrefs_darkScheme,
          kind: ForumPreferenceKind.choice,
          choices: {-1: l.forumPrefs_defaultValue, ...schemes},
        );
      }
    case ForumPreferenceSection.navigation:
      option('sidebar_link_to_filtered_list', l.forumPrefs_sidebarFiltered);
      option('sidebar_show_count_of_new_items', l.forumPrefs_sidebarCount);
      field(
        'sidebar_category_ids',
        l.forumPrefs_sidebarCategories,
        kind: ForumPreferenceKind.categories,
      );
      if (settings['tagging_enabled'] == true) {
        result.add(
          ForumPreferenceField(
            key: 'sidebar_tag_names',
            label: l.forumPrefs_sidebarTags,
            kind: ForumPreferenceKind.tagNames,
            choices: {
              for (final tag in data.records('sidebar_tags'))
                tag['name'] as Object: '${tag['name']}',
            },
          ),
        );
      }
    case ForumPreferenceSection.chat:
      option('chat_enabled', l.forumPrefs_chatEnabled);
      option('only_chat_push_notifications', l.forumPrefs_chatPushOnly);
      option('ignore_channel_wide_mention', l.forumPrefs_chatIgnoreMentions);
      option('show_thread_title_prompts', l.forumPrefs_chatThreads);
      option(
        'chat_header_indicator_preference',
        l.forumPrefs_chatIndicator,
        kind: ForumPreferenceKind.choice,
        choices: {
          'all_new': l.forumPrefs_allNew,
          'dm_and_mentions': l.forumPrefs_messagesMentions,
          'only_mentions': l.forumPrefs_mentionsOnly,
          'never': l.forumPrefs_never,
        },
      );
      option(
        'chat_send_shortcut',
        l.forumPrefs_chatShortcut,
        kind: ForumPreferenceKind.choice,
        choices: {'enter': 'Enter', 'meta_enter': 'Ctrl / ⌘ + Enter'},
      );
      option(
        'chat_separate_sidebar_mode',
        l.forumPrefs_chatSidebar,
        kind: ForumPreferenceKind.choice,
        choices: {
          'always': l.forumPrefs_always,
          'fullscreen': l.forumPrefs_fullscreen,
          'never': l.forumPrefs_never,
        },
      );
      option(
        'chat_quick_reaction_type',
        l.forumPrefs_chatReaction,
        kind: ForumPreferenceKind.choice,
        choices: {
          'frequent': l.forumPrefs_frequent,
          'custom': l.forumPrefs_custom,
        },
      );
      option(
        'chat_quick_reactions_custom',
        l.forumPrefs_chatEmojis,
        kind: ForumPreferenceKind.text,
        help: l.forumPrefs_chatEmojisHelp,
      );
      option(
        'chat_sound',
        l.forumPrefs_chatSound,
        kind: ForumPreferenceKind.choice,
        choices: {
          '': l.forumPrefs_none,
          'bell': l.forumPrefs_bell,
          'ding': l.forumPrefs_ding,
        },
      );
    case ForumPreferenceSection.security ||
        ForumPreferenceSection.apps ||
        ForumPreferenceSection.calendar:
      break;
  }
  return result;
}
