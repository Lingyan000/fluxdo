import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
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
  ForumPreferenceSection.chat => l.forumPrefs_chat,
  ForumPreferenceSection.apps => l.forumPrefs_apps,
  ForumPreferenceSection.calendar => l.forumPrefs_calendar,
};

String preferenceSectionDescription(
  ForumPreferenceSection section,
  AppLocalizations l,
) => switch (section) {
  ForumPreferenceSection.account =>
    '${l.forumPrefs_avatar} · ${l.forumPrefs_username} · ${l.forumPrefs_status}',
  ForumPreferenceSection.profile =>
    '${l.forumPrefs_bio} · ${l.forumPrefs_backgrounds}',
  ForumPreferenceSection.security =>
    '${l.forumPrefs_password} · ${l.forumPrefs_sessions}',
  ForumPreferenceSection.notifications =>
    '${l.forumPrefs_likeFrequency} · ${l.forumPrefs_schedule}',
  ForumPreferenceSection.emails =>
    '${l.forumPrefs_emailLevel} · ${l.forumPrefs_emailDigests}',
  ForumPreferenceSection.tracking =>
    '${l.forumPrefs_categories} · ${l.forumPrefs_tags} · ${l.forumPrefs_bookmarks}',
  ForumPreferenceSection.users =>
    '${l.forumPrefs_allowMessages} · ${l.forumPrefs_ignoredUsers}',
  ForumPreferenceSection.chat =>
    '${l.forumPrefs_chatEnabled} · ${l.forumPrefs_chatIgnoreMentions}',
  ForumPreferenceSection.apps => l.forumPrefs_appsDescription,
  ForumPreferenceSection.calendar => l.forumPrefs_calendarDescription,
};

IconData preferenceSectionIcon(ForumPreferenceSection section) =>
    switch (section) {
      ForumPreferenceSection.account => Symbols.account_circle_rounded,
      ForumPreferenceSection.security => Symbols.shield_rounded,
      ForumPreferenceSection.profile => Symbols.person_rounded,
      ForumPreferenceSection.notifications => Symbols.notifications_rounded,
      ForumPreferenceSection.emails => Symbols.mail_rounded,
      ForumPreferenceSection.tracking => Symbols.bookmark_rounded,
      ForumPreferenceSection.users => Symbols.group_rounded,
      ForumPreferenceSection.chat => Symbols.chat_bubble_rounded,
      ForumPreferenceSection.apps => Symbols.apps_rounded,
      ForumPreferenceSection.calendar => Symbols.calendar_month_rounded,
    };

List<ForumPreferenceField> preferenceFields(
  ForumPreferenceSection section,
  ForumPreferences data,
  AppLocalizations l,
) {
  final result = <ForumPreferenceField>[];
  var group = '';
  final user = data.user;
  final settings = data.settings;
  final options = data.options;
  void option(
    String key,
    String label, {
    ForumPreferenceKind kind = ForumPreferenceKind.toggle,
    Map<Object, String> choices = const {},
    String? help,
    String? enabledBy,
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
          group: group,
          enabledBy: enabledBy,
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
    String? enabledBy,
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
        group: group,
        enabledBy: enabledBy,
        emptyValue: emptyValue,
      ),
    );
  }

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
      final flairGroups = data
          .records('groups')
          .where(
            (group) => (group['flair_url'] as String?)?.isNotEmpty == true,
          );
      if (flairGroups.isNotEmpty) {
        field(
          'flair_group_id',
          l.forumPrefs_flairGroup,
          kind: ForumPreferenceKind.flair,
          help: l.forumPrefs_flairHelp,
          choices: {
            0: l.forumPrefs_none,
            for (final group in flairGroups)
              group['id'] as Object: '${group['name']}',
          },
        );
      }
    case ForumPreferenceSection.profile:
      group = l.forumPrefs_basicProfile;
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
          kind: ForumPreferenceKind.birthday,
        );
      }
      group = l.forumPrefs_backgrounds;
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
      group = l.forumPrefs_basicProfile;
      option(
        'timezone',
        l.forumPrefs_timezone,
        kind: ForumPreferenceKind.choice,
        choices: {
          for (final zone in tz.timeZoneDatabase.locations.keys) zone: zone,
        },
      );
      group = l.forumPrefs_privacy;
      option('hide_profile', l.forumPrefs_hideProfile);
      option('hide_presence', l.forumPrefs_hidePresence);
      group = l.forumPrefs_extraProfile;
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
            group: group,
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
      group = l.forumPrefs_emailDigests;
      option('email_digests', l.forumPrefs_emailDigests);
      option(
        'digest_after_minutes',
        l.forumPrefs_digestFrequency,
        enabledBy: 'user_option.email_digests',
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
      option(
        'include_tl0_in_digests',
        l.forumPrefs_includeNewUsers,
        enabledBy: 'user_option.email_digests',
      );
      group = l.forumPrefs_mailingList;
      if (settings['disable_mailing_list_mode'] != true) {
        option('mailing_list_mode', l.forumPrefs_mailingList);
        option(
          'mailing_list_mode_frequency',
          l.forumPrefs_mailingFrequency,
          enabledBy: 'user_option.mailing_list_mode',
          kind: ForumPreferenceKind.choice,
          choices: {1: l.forumPrefs_allPosts, 2: l.forumPrefs_exceptOwn},
        );
      }
      group = l.forumPrefs_chat;
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
      group = l.forumPrefs_categories;
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
        group = l.forumPrefs_tags;
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
      group = l.forumPrefs_tracking;
      option('watched_precedence_over_muted', l.forumPrefs_watchPrecedence);
      option('topics_unread_when_closed', l.forumPrefs_unreadClosed);
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
    case ForumPreferenceSection.users:
      option('allow_private_messages', l.forumPrefs_allowMessages);
      option('enable_allowed_pm_users', l.forumPrefs_onlyAllowed);
      field(
        'allowed_pm_usernames',
        enabledBy: 'user_option.enable_allowed_pm_users',
        l.forumPrefs_allowedUsers,
        kind: ForumPreferenceKind.usernames,
      );
      field(
        'muted_usernames',
        l.forumPrefs_mutedUsers,
        kind: ForumPreferenceKind.usernames,
        permission: 'can_mute_users',
      );
    case ForumPreferenceSection.chat:
      option('chat_enabled', l.forumPrefs_chatEnabled);
      option('only_chat_push_notifications', l.forumPrefs_chatPushOnly);
      option('ignore_channel_wide_mention', l.forumPrefs_chatIgnoreMentions);
    case ForumPreferenceSection.calendar ||
        ForumPreferenceSection.security ||
        ForumPreferenceSection.apps:
      break;
  }
  return result;
}
