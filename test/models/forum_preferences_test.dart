import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/forum_preferences.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/forum_preferences/preference_fields.dart';
import 'package:fluxdo/l10n/s.dart';

void main() {
  test('原生设置保留服务端行为，过滤网页外观与侧栏配置', () {
    final data = ForumPreferences(
      user: {
        'username': 'tester',
        'can_change_tracking_preferences': true,
        'user_option': {
          'hide_presence': true,
          'bookmark_auto_delete_preference': 2,
          'theme_ids': [1],
          'text_size': 'largest',
          'sidebar_link_to_filtered_list': true,
          'chat_send_shortcut': 'enter',
          'chat_enabled': true,
          'ignore_channel_wide_mention': true,
        },
      },
      site: {},
      settings: {'chat_enabled': true},
    );
    final l10n = AppLocale.zh.buildSync();
    final fields = ForumPreferenceSection.values.expand(
      (section) => preferenceFields(section, data, l10n),
    );
    final keys = fields.map((field) => field.key).toSet();
    expect(
      keys,
      containsAll([
        'hide_presence',
        'bookmark_auto_delete_preference',
        'chat_enabled',
        'ignore_channel_wide_mention',
      ]),
    );
    expect(
      keys.intersection({
        'theme_ids',
        'text_size',
        'sidebar_link_to_filtered_list',
        'chat_send_shortcut',
      }),
      isEmpty,
    );
  });

  test('只提交修改字段，保留未知用户选项', () {
    const name = ForumPreferenceField(key: 'name', label: '名称');
    const notify = ForumPreferenceField(
      key: 'notify_on_linked_posts',
      label: '通知',
      container: 'user_option',
      kind: ForumPreferenceKind.toggle,
    );
    final draft = ForumPreferenceDraft(
      [name, notify],
      {
        'name': '原名',
        'user_option': {'notify_on_linked_posts': false, 'future_option': 7},
      },
    );
    expect(draft.payload, isEmpty);
    draft.update(name, '新名');
    expect(draft.payload, {'name': '新名'});
    draft.update(name, '原名');
    draft.update(notify, true);
    expect(draft.payload, {'notify_on_linked_posts': true});
    expect(draft.user['user_option']['future_option'], 7);
  });

  test('清空分类、标签与导航遵循各自协议', () {
    const category = ForumPreferenceField(
      key: 'watched_category_ids',
      label: '分类',
      kind: ForumPreferenceKind.categories,
      emptyValue: [-1],
    );
    const tag = ForumPreferenceField(
      key: 'watched_tags',
      label: '标签',
      kind: ForumPreferenceKind.tags,
    );
    const sidebar = ForumPreferenceField(
      key: 'sidebar_tag_names',
      label: '导航',
      kind: ForumPreferenceKind.tagNames,
    );
    final draft = ForumPreferenceDraft(
      [category, tag, sidebar],
      {
        'watched_category_ids': [1],
        'watched_tags': ['dart'],
        'sidebar_tag_names': ['flutter'],
      },
    );
    for (final field in draft.fields) {
      draft.update(field, <Object>[]);
    }
    expect(draft.payload, {
      'watched_category_ids': [-1],
      'watched_tags': '',
      'sidebar_tag_names': null,
    });
  });

  test('改变分类通知级别时同时清空旧级别', () {
    const watched = ForumPreferenceField(
      key: 'watched_category_ids',
      label: '关注',
      kind: ForumPreferenceKind.categories,
      emptyValue: [-1],
    );
    const muted = ForumPreferenceField(
      key: 'muted_category_ids',
      label: '静音',
      kind: ForumPreferenceKind.categories,
      emptyValue: [-1],
    );
    final draft = ForumPreferenceDraft(
      [watched, muted],
      {
        'watched_category_ids': [1, 2],
        'muted_category_ids': [],
      },
    );
    draft.update(muted, [1]);
    expect(draft.payload, {
      'watched_category_ids': [2],
      'muted_category_ids': [1],
    });
  });

  test('自定义确认字段提交字符串并保留未编辑字段', () {
    const field = ForumPreferenceField(
      key: '3',
      label: '确认',
      kind: ForumPreferenceKind.toggle,
      container: 'user_fields',
    );
    final draft = ForumPreferenceDraft(
      [field],
      {
        'user_fields': {'3': 'true', '4': '保留'},
      },
    );
    draft.update(field, false);
    expect(draft.payload, {
      'user_fields': {'3': 'false'},
    });
    expect(draft.user['user_fields']['4'], '保留');
  });

  test('修改通知时间表不改变原始对象', () {
    const field = ForumPreferenceField(
      key: 'user_notification_schedule',
      label: '时间表',
      kind: ForumPreferenceKind.schedule,
    );
    final original = {
      'enabled': false,
      'day_0_start_time': 0,
      'day_0_end_time': 1440,
    };
    final draft = ForumPreferenceDraft(
      [field],
      {'user_notification_schedule': original},
    );
    (draft.values[field.id] as Map)['enabled'] = true;
    expect(original['enabled'], false);
    expect(draft.dirty, true);
  });

  test('清空自定义多选字段仍发送字段键', () {
    const field = ForumPreferenceField(
      key: '8',
      label: '多选',
      container: 'user_fields',
      kind: ForumPreferenceKind.multiChoice,
    );
    final draft = ForumPreferenceDraft(
      [field],
      {
        'user_fields': {
          '8': ['one'],
        },
      },
    );
    draft.update(field, <Object>[]);
    expect(draft.payload, {
      'user_fields': {'8': null},
    });
  });

  test('历史统计缓存与隐私标记均可读取', () {
    final old = UserSummary.fromCacheJson({'topic_count': 4});
    expect(old.canSeeSummaryStats, true);
    final hidden = UserSummary.fromJson({
      'user_summary': {
        'can_see_summary_stats': false,
        'can_see_user_actions': false,
      },
    });
    final cached = UserSummary.fromCacheJson(hidden.toCacheJson());
    expect(cached.canSeeSummaryStats, false);
    expect(cached.canSeeUserActions, false);
    final user = User.fromJson({
      'id': 1,
      'username': 'hidden',
      'avatar_template': '',
      'profile_hidden': true,
    });
    expect(user.profileHidden, true);
    expect(user.canEdit, false);
  });
}
