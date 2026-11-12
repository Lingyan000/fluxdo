import 'dart:convert';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/forum_preferences.dart';
import '../../models/user.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../../services/preloaded_data_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/discourse_url_parser.dart';
import '../../utils/error_utils.dart';
import '../../utils/time_utils.dart';
import '../../utils/url_helper.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../widgets/user/ignore_duration_picker.dart';
import '../webview_page.dart';
import 'preference_controls.dart';
import 'preference_fields.dart';

class PreferenceActions extends StatefulWidget {
  const PreferenceActions({
    super.key,
    required this.section,
    required this.data,
    required this.onChanged,
    required this.onBusy,
  });
  final ForumPreferenceSection section;
  final ForumPreferences data;
  final Future<void> Function({String? username, bool signedOut}) onChanged;
  final ValueChanged<bool> onBusy;
  @override
  State<PreferenceActions> createState() => _PreferenceActionsState();
}

class _PreferenceActionsState extends State<PreferenceActions> {
  final _service = DiscourseService();
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _emails;
  Map<String, dynamic>? _factors;
  Map<String, dynamic>? _calendar;

  String get _username => widget.data.username;
  bool get _localLogin =>
      widget.data.settings['enable_discourse_connect'] != true &&
      widget.data.settings['enable_local_logins'] == true &&
      widget.data.user['is_anonymous'] != true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = switch (widget.section) {
        ForumPreferenceSection.account => await _service.getPreferenceEmails(
          _username,
        ),
        ForumPreferenceSection.calendar =>
          await _service.preferenceCalendarSubscription(),
        _ => null,
      };
      if (!mounted) return;
      setState(() {
        if (widget.section == ForumPreferenceSection.account) _emails = data;
        if (widget.section == ForumPreferenceSection.calendar) _calendar = data;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusy(true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      widget.onBusy(false);
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
  Widget _action(
    String title,
    VoidCallback action, {
    String? subtitle,
    IconData? icon,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading: Icon(
      icon ?? preferenceSectionIcon(widget.section),
      color: context.emphasis.accent,
    ),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: const Icon(Symbols.chevron_right_rounded),
    onTap: _busy ? null : action,
  );

  Future<bool> _trusted() async {
    if (await _service.isPreferenceSessionTrusted()) return true;
    if (!mounted) return false;
    return editPreferenceValue(
      context,
      title: context.l10n.forumPrefs_confirmPassword,
      obscure: true,
      submit: _service.confirmPreferenceSession,
    );
  }

  Future<void> _changeUsername() => _run(() async {
    String? changed;
    final saved = await editPreferenceValue(
      context,
      title: context.l10n.forumPrefs_username,
      initialValue: _username,
      submit: (value) async {
        await _service.changePreferenceUsername(_username, value);
        changed = value;
      },
    );
    if (saved) await widget.onChanged(username: changed);
  });

  Future<void> _changeEmail({bool add = false}) => _run(() async {
    final saved = await editPreferenceValue(
      context,
      title: add
          ? context.l10n.forumPrefs_addEmail
          : context.l10n.forumPrefs_email,
      submit: (value) =>
          _service.changePreferenceEmail(_username, value, add: add),
    );
    if (!saved || !mounted) return;
    ToastService.showSuccess(context.l10n.forumPrefs_confirmationSent);
    await _load();
    await widget.onChanged();
  });

  Future<void> _emailAction(String email, {bool primary = false}) =>
      _run(() async {
        if (!await confirmPreferenceAction(
          context,
          primary
              ? context.l10n.forumPrefs_makePrimary
              : context.l10n.common_remove,
          message: email,
        )) {
          return;
        }
        await _service.changePreferenceEmail(
          _username,
          email,
          primary: primary,
          remove: !primary,
        );
        await _load();
        await widget.onChanged();
      });

  Future<void> _avatar({bool reset = false}) => _run(() async {
    int uploadId = 0;
    if (!reset) {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );
      final path = selected?.files.single.path;
      if (path == null) return;
      final upload = await _service.uploadFile(path, uploadType: 'avatar');
      if (upload.id == null) throw StateError('Missing avatar upload ID');
      uploadId = upload.id!;
    }
    await _service.pickPreferenceAvatar(
      _username,
      uploadId,
      reset ? 'system' : 'uploaded',
    );
    await widget.onChanged();
  });

  List<Widget> _account() {
    final l = context.l10n;
    final user = widget.data.user;
    final avatar = User.fromJson(user).getAvatarUrl(size: 144);
    return [
      _action(
        l.forumPrefs_title,
        _chooseTitle,
        subtitle: user['title'] as String?,
      ),
      if (user['can_edit_username'] == true)
        _action(l.forumPrefs_username, _changeUsername, subtitle: _username),
      _heading(l.forumPrefs_avatar),
      Row(
        children: [
          SmartAvatar(imageUrl: avatar, radius: 32, fallbackText: _username),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              spacing: 8,
              children: [
                if (widget
                            .data
                            .settings['discourse_connect_overrides_avatar'] !=
                        true &&
                    widget.data.settings['auth_overrides_avatar'] != true) ...[
                  OutlinedButton(
                    onPressed: _busy ? null : _avatar,
                    child: Text(l.forumPrefs_upload),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _avatar(reset: true),
                    child: Text(l.common_reset),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      _heading(l.forumPrefs_email),
      if (_emails == null && _error == null) const M3eLinearProgress(),
      if (_emails != null) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${_emails!['email'] ?? ''}'),
          trailing: user['can_edit_email'] == true
              ? IconButton(
                  tooltip: l.common_edit,
                  icon: const Icon(Symbols.edit_rounded),
                  onPressed: _busy ? null : _changeEmail,
                )
              : null,
        ),
        for (final email in _emails!['secondary_emails'] as List? ?? [])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('$email'),
            trailing: Wrap(
              children: [
                if (user['can_edit_email'] == true)
                  IconButton(
                    tooltip: l.forumPrefs_makePrimary,
                    onPressed: _busy
                        ? null
                        : () => _emailAction('$email', primary: true),
                    icon: const Icon(Symbols.star_rounded),
                  ),
                if (user['can_edit_email'] == true)
                  IconButton(
                    tooltip: l.common_remove,
                    onPressed: _busy ? null : () => _emailAction('$email'),
                    icon: const Icon(Symbols.delete_rounded),
                  ),
              ],
            ),
          ),
        for (final email in _emails!['unconfirmed_emails'] as List? ?? [])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('$email'),
            subtitle: Text(l.forumPrefs_pendingEmail),
            trailing: user['can_edit_email'] == true
                ? IconButton(
                    tooltip: l.common_remove,
                    onPressed: _busy ? null : () => _emailAction('$email'),
                    icon: const Icon(Symbols.delete_rounded),
                  )
                : null,
          ),
      ],
      if (user['can_edit_email'] == true &&
          ((widget.data.settings['max_allowed_secondary_emails'] as num?) ??
                  0) >
              0)
        _action(l.forumPrefs_addEmail, () => _changeEmail(add: true)),
      if (widget.data.settings['enable_user_status'] == true) ...[
        _heading(l.forumPrefs_status),
        _action(
          l.forumPrefs_status,
          _editStatus,
          subtitle: (user['status'] as Map?)?['description'] as String?,
        ),
      ],
      if (widget.data.records('associated_accounts').isNotEmpty)
        _heading(l.forumPrefs_connectedAccounts),
      for (final account in widget.data.records('associated_accounts'))
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${account['name'] ?? account['provider_name']}'),
          subtitle: Text('${account['description'] ?? ''}'),
          trailing: TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    if (!await confirmPreferenceAction(
                      context,
                      l.forumPrefs_revokeConfirm,
                    )) {
                      return;
                    }
                    await _service.revokePreferenceAccount(
                      _username,
                      '${account['name'] ?? account['provider_name']}',
                    );
                    await widget.onChanged();
                  }),
            child: Text(l.forumPrefs_revoke),
          ),
        ),
      if ((widget.data.site['auth_providers'] as List? ?? []).isNotEmpty)
        _action(
          l.forumPrefs_connectedAccountAdd,
          () => _run(() async {
            await WebViewPage.open(
              context,
              UrlHelper.resolveUrl(
                '/u/${Uri.encodeComponent(_username)}/preferences/account',
              ),
              title: l.forumPrefs_connectedAccounts,
            );
            await widget.onChanged();
          }),
        ),
      _action(
        l.forumPrefs_exportArchive,
        () => _run(() async {
          if (!await confirmPreferenceAction(
            context,
            l.forumPrefs_exportArchive,
            message: l.forumPrefs_exportArchiveHelp,
          )) {
            return;
          }
          await _service.exportPreferenceArchive();
          if (mounted) ToastService.showSuccess(l.forumPrefs_archiveRequested);
        }),
      ),
      if (widget.data.settings['enable_discourse_connect'] != true &&
          PreloadedDataService().currentUserSync?['can_delete_account'] == true)
        _action(
          l.forumPrefs_deleteAccount,
          () => _run(() async {
            final deleted = await editPreferenceValue(
              context,
              title: l.forumPrefs_deleteAccount,
              help: l.forumPrefs_deleteAccountHelp,
              submit: (value) async {
                if (value != _username) {
                  throw FormatException(l.forumPrefs_invalidValue);
                }
                await _service.deletePreferenceAccount(_username);
              },
            );
            if (deleted) {
              await _service.logout(callApi: false);
              await widget.onChanged(signedOut: true);
            }
          }),
        ),
    ];
  }

  Future<void> _chooseTitle() => _run(() async {
    final choices = <Object, String>{'': context.l10n.forumPrefs_none};
    for (final group in widget.data.records('groups')) {
      final title = group['title'];
      if (title is String && title.isNotEmpty) choices[title] = title;
    }
    if (widget.data.settings['enable_badges'] == true) {
      final response = await _service.getUserBadges(username: _username);
      for (final awarded in response.userBadges) {
        final badge = awarded.badge;
        if (badge != null && badge.allowTitle) choices[badge.name] = badge.name;
      }
    }
    if (!mounted) return;
    final title = await selectPreferenceValues(
      context,
      title: context.l10n.forumPrefs_title,
      choices: choices,
      selected: [widget.data.user['title'] ?? ''],
      multiple: false,
    );
    if (title == null) return;
    await _service.saveForumPreferences(_username, {'title': title.single});
    await widget.onChanged();
  });

  Future<void> _editStatus() => _run(() async {
    final status = Map<String, dynamic>.from(
      widget.data.user['status'] as Map? ?? {},
    );
    final saved = await showAppDialog<bool>(
      context: context,
      builder: (_) => _StatusDialog(
        status: status,
        submit: (value) =>
            _service.saveForumPreferences(_username, {'status': value}),
      ),
    );
    if (saved == true) await widget.onChanged();
  });

  List<Widget> _profile() => [
    SegmentedCardGroup(
      children: [
        _action(
          context.l10n.forumPrefs_featuredTopic,
          () => _run(() async {
            final saved = await editPreferenceValue(
              context,
              title: context.l10n.forumPrefs_featuredTopic,
              help: context.l10n.forumPrefs_featuredTopicHint,
              submit: (value) async {
                final id =
                    int.tryParse(value) ??
                    DiscourseUrlParser.parseTopic(value)?.topicId;
                if (id == null || id <= 0) {
                  throw FormatException(context.l10n.forumPrefs_invalidValue);
                }
                await _service.featureProfileTopic(_username, id);
              },
            );
            if (saved) await widget.onChanged();
          }),
          icon: Symbols.push_pin_rounded,
          subtitle:
              (widget.data.user['featured_topic'] as Map?)?['title'] as String?,
        ),
        if (widget.data.user['featured_topic'] != null)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _service.featureProfileTopic(_username, null);
                    await widget.onChanged();
                  }),
            icon: const Icon(Symbols.delete_outline_rounded),
            label: Text(context.l10n.common_remove),
          ),
      ],
    ),
  ];

  Future<void> _loadFactors() => _run(() async {
    if (!await _trusted()) return;
    final factors = await _service.getPreferenceSecondFactors();
    if (mounted) setState(() => _factors = factors);
  });

  Future<void> _addTotp() => _run(() async {
    if (!await _trusted() || !mounted) return;
    final saved = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TotpDialog(service: _service),
    );
    if (saved == true) {
      _factors = await _service.getPreferenceSecondFactors();
      await widget.onChanged();
    }
  });

  Future<void> _backupCodes() => _run(() async {
    if (!await confirmPreferenceAction(
      context,
      context.l10n.forumPrefs_generateCodes,
      message: context.l10n.forumPrefs_recoveryHelp,
    )) {
      return;
    }
    if (!await _trusted()) return;
    final result = await _service.generatePreferenceBackupCodes();
    if (!mounted) return;
    final codes = (result['backup_codes'] as List).join('\n');
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.forumPrefs_recoveryCodes),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.forumPrefs_recoveryHelp),
              const SizedBox(height: 16),
              SelectableText(codes),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: codes)),
            child: Text(context.l10n.common_copy),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.common_close),
          ),
        ],
      ),
    );
    await widget.onChanged();
  });

  Future<void> _factorAction(
    Map factor, {
    bool securityKey = false,
    bool remove = false,
  }) => _run(() async {
    if (!await _trusted() || !mounted) return;
    bool saved = false;
    if (remove) {
      if (!await confirmPreferenceAction(
        context,
        context.l10n.common_delete,
        message: '${factor['name']}',
      )) {
        return;
      }
      await _service.updatePreferenceSecondFactor(
        factor['id'] as Object,
        '${factor['name']}',
        remove: true,
        securityKey: securityKey,
      );
      saved = true;
    } else {
      saved = await editPreferenceValue(
        context,
        title: context.l10n.common_edit,
        initialValue: '${factor['name']}',
        submit: (value) => _service.updatePreferenceSecondFactor(
          factor['id'] as Object,
          value,
          securityKey: securityKey,
        ),
      );
    }
    if (saved) {
      _factors = await _service.getPreferenceSecondFactors();
      await widget.onChanged();
    }
  });

  Future<void> _passkeyAction(Map passkey, {bool remove = false}) =>
      _run(() async {
        if (!await _trusted() || !mounted) return;
        if (remove) {
          if (!await confirmPreferenceAction(
            context,
            context.l10n.common_delete,
            message: '${passkey['name']}',
          )) {
            return;
          }
          await _service.updatePreferencePasskey(
            passkey['id'] as Object,
            remove: true,
          );
        } else {
          final saved = await editPreferenceValue(
            context,
            title: context.l10n.common_edit,
            initialValue: '${passkey['name']}',
            submit: (value) => _service.updatePreferencePasskey(
              passkey['id'] as Object,
              name: value,
            ),
          );
          if (!saved) return;
        }
        await widget.onChanged();
      });

  List<Widget> _security() {
    final l = context.l10n;
    return [
      if (_localLogin) ...[
        _heading(l.forumPrefs_password),
        _action(
          l.forumPrefs_resetPassword,
          () => _run(() async {
            await _service.sendPreferencePasswordReset(_username);
            if (mounted) {
              ToastService.showSuccess(
                context.l10n.forumPrefs_confirmationSent,
              );
            }
          }),
        ),
        if (widget.data.user['no_password'] != true &&
            (widget.data.records('associated_accounts').isNotEmpty ||
                widget.data.records('user_passkeys').isNotEmpty))
          _action(
            l.forumPrefs_removePassword,
            () => _run(() async {
              if (!await confirmPreferenceAction(
                context,
                l.forumPrefs_removePassword,
                message: l.forumPrefs_removePasswordHelp,
              )) {
                return;
              }
              if (!await _trusted()) return;
              await _service.removePreferencePassword(_username);
              await widget.onChanged();
            }),
          ),
        _heading(l.forumPrefs_twoFactor),
        _action(l.forumPrefs_addAuthenticator, _addTotp),
        if (_factors == null) _action(l.forumPrefs_authenticator, _loadFactors),
        if (_factors != null) ...[
          for (final factor in _factors!['totps'] as List? ?? [])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${factor['name']}'),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: l.common_edit,
                    onPressed: _busy
                        ? null
                        : () => _factorAction(factor as Map),
                    icon: const Icon(Symbols.edit_rounded),
                  ),
                  IconButton(
                    tooltip: l.common_delete,
                    onPressed: _busy
                        ? null
                        : () => _factorAction(factor as Map, remove: true),
                    icon: const Icon(Symbols.delete_rounded),
                  ),
                ],
              ),
            ),
          if ((_factors!['security_keys'] as List? ?? []).isNotEmpty)
            _heading(l.forumPrefs_securityKeys),
          for (final factor in _factors!['security_keys'] as List? ?? [])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${factor['name']}'),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: l.common_edit,
                    onPressed: _busy
                        ? null
                        : () => _factorAction(factor as Map, securityKey: true),
                    icon: const Icon(Symbols.edit_rounded),
                  ),
                  IconButton(
                    tooltip: l.common_delete,
                    onPressed: _busy
                        ? null
                        : () => _factorAction(
                            factor as Map,
                            securityKey: true,
                            remove: true,
                          ),
                    icon: const Icon(Symbols.delete_rounded),
                  ),
                ],
              ),
            ),
        ],
        if (widget.data.user['second_factor_enabled'] == true)
          _action(l.forumPrefs_generateCodes, _backupCodes),
        if (widget.data.settings['enable_passkeys'] == true) ...[
          _heading(l.forumPrefs_passkeys),
          for (final passkey in widget.data.records('user_passkeys'))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${passkey['name']}'),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: l.common_edit,
                    onPressed: _busy ? null : () => _passkeyAction(passkey),
                    icon: const Icon(Symbols.edit_rounded),
                  ),
                  IconButton(
                    tooltip: l.common_delete,
                    onPressed: _busy
                        ? null
                        : () => _passkeyAction(passkey, remove: true),
                    icon: const Icon(Symbols.delete_rounded),
                  ),
                ],
              ),
            ),
        ],
        _action(
          l.forumPrefs_browserSecurity,
          () => _run(() async {
            await WebViewPage.open(
              context,
              UrlHelper.resolveUrl(
                '/u/${Uri.encodeComponent(_username)}/preferences/second-factor',
              ),
              title: l.forumPrefs_security,
            );
            await widget.onChanged();
          }),
        ),
      ],
      _heading(l.forumPrefs_sessions),
      for (final session in widget.data.records('user_auth_tokens'))
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${session['device'] ?? ''} · ${session['browser'] ?? ''}',
          ),
          subtitle: Text(
            [
              if (session['is_active'] == true) l.forumPrefs_currentSession,
              '${session['location'] ?? ''}',
              TimeUtils.formatFullDate(
                TimeUtils.parseUtcTime(session['seen_at'] as String?),
              ),
            ].where((value) => value.isNotEmpty).join('\n'),
          ),
          trailing: IconButton(
            tooltip: l.forumPrefs_revoke,
            onPressed: _busy
                ? null
                : () => _run(() async {
                    if (!await confirmPreferenceAction(
                      context,
                      l.forumPrefs_revokeConfirm,
                    )) {
                      return;
                    }
                    await _service.revokePreferenceSession(
                      _username,
                      session['id'] as Object,
                    );
                    if (session['is_active'] == true) {
                      await _service.logout(callApi: false);
                    }
                    await widget.onChanged(
                      signedOut: session['is_active'] == true,
                    );
                  }),
            icon: const Icon(Symbols.logout_rounded),
          ),
        ),
    ];
  }

  List<Widget> _users() => [
    if (widget.data.user['can_ignore_users'] == true) ...[
      _heading(context.l10n.forumPrefs_ignoredUsers),
      for (final username
          in widget.data.user['ignored_usernames'] as List? ?? [])
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('$username'),
          trailing: IconButton(
            tooltip: context.l10n.common_remove,
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _service.updateUserNotificationLevel(
                      '$username',
                      level: 'normal',
                    );
                    await widget.onChanged();
                  }),
            icon: const Icon(Symbols.remove_circle_outline_rounded),
          ),
        ),
      _action(
        context.l10n.common_add,
        () => _run(() async {
          final saved = await editPreferenceValue(
            context,
            title: context.l10n.forumPrefs_ignoredUsers,
            submit: (username) async {
              final expiry = await showIgnoreDurationPicker(context);
              if (expiry == null || !mounted) return;
              await _service.updateUserNotificationLevel(
                username,
                level: 'ignore',
                expiringAt: expiry,
              );
            },
          );
          if (saved) await widget.onChanged();
        }),
      ),
    ],
  ];

  List<Widget> _apps() {
    final apps = widget.data.records('user_api_keys');
    return [
      if (apps.isEmpty) Text(context.l10n.forumPrefs_empty),
      for (final app in apps)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${app['application_name']}'),
          subtitle: Text((app['scopes'] as List? ?? []).join('\n')),
          trailing: TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final id = app['id'] as Object;
                    final restore = app['revoked'] == true;
                    if (!restore &&
                        !await confirmPreferenceAction(
                          context,
                          context.l10n.forumPrefs_revokeConfirm,
                          message: '${app['application_name']}',
                        )) {
                      return;
                    }
                    await _service.revokePreferenceApp(id, restore: restore);
                    setState(() {
                      app['revoked'] = !restore;
                      widget.data.user['user_api_keys'] = apps;
                    });
                  }),
            child: Text(
              app['revoked'] == true
                  ? context.l10n.forumPrefs_restore
                  : context.l10n.forumPrefs_revoke,
            ),
          ),
        ),
    ];
  }

  List<Widget> _calendarWidgets() {
    if (_calendar == null) {
      return [if (_error == null) const M3eLinearProgress()];
    }
    final active = _calendar!['has_subscription'] == true;
    final urls = _calendar!['urls'] as Map? ?? {};
    return [
      Text(
        active
            ? context.l10n.forumPrefs_calendarActive
            : context.l10n.forumPrefs_calendarInactive,
      ),
      for (final url in urls.entries)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${url.key}'),
          subtitle: SelectableText('${url.value}'),
          trailing: IconButton(
            tooltip: context.l10n.common_copy,
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: '${url.value}')),
            icon: const Icon(Symbols.content_copy_rounded),
          ),
        ),
      _action(
        active
            ? context.l10n.forumPrefs_rotateCalendar
            : context.l10n.forumPrefs_generateCalendar,
        () => _run(() async {
          if (active &&
              !await confirmPreferenceAction(
                context,
                context.l10n.forumPrefs_rotateCalendar,
                message: context.l10n.forumPrefs_rotateCalendarConfirm,
              )) {
            return;
          }
          final result = await _service.preferenceCalendarSubscription(
            generate: true,
          );
          if (mounted) {
            setState(() => _calendar = {...result, 'has_subscription': true});
          }
        }),
      ),
      if (active)
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  if (!await confirmPreferenceAction(
                    context,
                    context.l10n.forumPrefs_revokeConfirm,
                  )) {
                    return;
                  }
                  await _service.preferenceCalendarSubscription(revoke: true);
                  if (mounted) {
                    setState(() => _calendar = {'has_subscription': false});
                  }
                }),
          child: Text(context.l10n.forumPrefs_revoke),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_busy) const M3eLinearProgress(),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              if (widget.section == ForumPreferenceSection.account ||
                  widget.section == ForumPreferenceSection.calendar)
                IconButton(
                  tooltip: context.l10n.common_retry,
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Symbols.refresh_rounded),
                ),
            ],
          ),
        ),
      ...switch (widget.section) {
        ForumPreferenceSection.account => _account(),
        ForumPreferenceSection.profile => _profile(),
        ForumPreferenceSection.security => _security(),
        ForumPreferenceSection.users => _users(),
        ForumPreferenceSection.apps => _apps(),
        ForumPreferenceSection.calendar => _calendarWidgets(),
        ForumPreferenceSection.interface => [
          _action(
            context.l10n.forumPrefs_resetTips,
            () => _run(() async {
              await _service.saveForumPreferences(_username, {
                'skip_new_user_tips': false,
                'seen_popups': null,
              });
              await widget.onChanged();
            }),
          ),
        ],
        _ => <Widget>[],
      },
    ],
  );
}

class _TotpDialog extends StatefulWidget {
  const _TotpDialog({required this.service});
  final DiscourseService service;
  @override
  State<_TotpDialog> createState() => _TotpDialogState();
}

class _TotpDialogState extends State<_TotpDialog> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  Map<String, dynamic>? _secret;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    try {
      final secret = await widget.service.createPreferenceTotp();
      if (mounted) {
        setState(() {
          _secret = secret;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _code.text.trim().isEmpty) {
      setState(() => _error = context.l10n.forumPrefs_required);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.enablePreferenceTotp(
        _code.text.trim(),
        _name.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(context.l10n.forumPrefs_addAuthenticator),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.forumPrefs_authenticatorHelp),
              const SizedBox(height: 16),
              if (_secret == null && _error == null) const M3eLinearProgress(),
              if (_secret != null) ...[
                if ((_secret!['qr'] as String?)?.startsWith(
                      'data:image/png;base64,',
                    ) ==
                    true)
                  Center(
                    child: Image.memory(
                      base64Decode((_secret!['qr'] as String).split(',').last),
                      width: 200,
                      height: 200,
                    ),
                  ),
                SelectableText('${_secret!['key']}'),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  maxLength: 50,
                  decoration: InputDecoration(
                    labelText: context.l10n.forumPrefs_authenticatorName,
                  ),
                ),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.forumPrefs_verificationCode,
                  ),
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.common_cancel),
        ),
        if (_secret == null && _error != null)
          TextButton(
            onPressed: _create,
            child: Text(context.l10n.common_retry),
          ),
        FilledButton(
          onPressed: _saving || _secret == null ? null : _save,
          child: Text(
            _saving ? context.l10n.common_loading : context.l10n.common_save,
          ),
        ),
      ],
    ),
  );
}

class _StatusDialog extends StatefulWidget {
  const _StatusDialog({required this.status, required this.submit});
  final Map<String, dynamic> status;
  final Future<void> Function(Map<String, dynamic>?) submit;
  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late final _description = TextEditingController(
    text: '${widget.status['description'] ?? ''}',
  );
  late final _emoji = TextEditingController(
    text: '${widget.status['emoji'] ?? ''}',
  );
  bool _saving = false;
  int _expirySeconds = -1;
  String? _error;
  @override
  void dispose() {
    _description.dispose();
    _emoji.dispose();
    super.dispose();
  }

  Future<void> _save({bool clear = false}) async {
    setState(() => _saving = true);
    try {
      await widget.submit(
        clear
            ? null
            : {
                'description': _description.text.trim(),
                'emoji': _emoji.text.trim(),
                'ends_at': clear || _expirySeconds == 0
                    ? null
                    : _expirySeconds == -1
                    ? widget.status['ends_at']
                    : DateTime.now()
                          .toUtc()
                          .add(Duration(seconds: _expirySeconds))
                          .toIso8601String(),
              },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(context.l10n.forumPrefs_status),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _description,
                decoration: InputDecoration(
                  labelText: context.l10n.forumPrefs_statusDescription,
                ),
              ),
              TextField(
                controller: _emoji,
                decoration: InputDecoration(
                  labelText: context.l10n.forumPrefs_statusEmoji,
                ),
              ),
              DropdownButtonFormField<int>(
                initialValue: _expirySeconds,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: context.l10n.forumPrefs_statusExpiry,
                ),
                items:
                    {
                          -1: context.l10n.forumPrefs_keepExpiry,
                          0: context.l10n.forumPrefs_noExpiry,
                          3600: context.l10n.forumPrefs_hour1,
                          86400: context.l10n.forumPrefs_day1,
                        }.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _expirySeconds = value!),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => _save(clear: true),
          child: Text(context.l10n.common_remove),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(context.l10n.common_save),
        ),
      ],
    ),
  );
}
