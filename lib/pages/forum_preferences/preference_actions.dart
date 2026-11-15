import 'dart:convert';
import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/forum_preferences.dart';
import '../../models/user.dart';
import '../../providers/core_providers.dart';
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
import 'status_dialog.dart';
import '../chat/new_chat_sheet.dart';

class PreferenceActions extends ConsumerStatefulWidget {
  const PreferenceActions({
    super.key,
    required this.section,
    required this.data,
    required this.onChanged,
    required this.onBusy,
  });
  final ForumPreferenceSection section;
  final ForumPreferences data;
  final Future<void> Function({String? username, bool signedOut, bool reload})
  onChanged;
  final ValueChanged<bool> onBusy;
  @override
  ConsumerState<PreferenceActions> createState() => _PreferenceActionsState();
}

class _PreferenceActionsState extends ConsumerState<PreferenceActions> {
  final _service = DiscourseService();
  bool _busy = false;
  bool _avatarBusy = false;
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

  Widget _group(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: context.emphasis.accent),
            ),
          ),
        SegmentedCardGroup(children: children),
      ],
    ),
  );
  Widget _action(
    String title,
    VoidCallback action, {
    String? subtitle,
    IconData? icon,
    Widget? leading,
    bool destructive = false,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    leading:
        leading ??
        Icon(
          icon ?? preferenceSectionIcon(widget.section),
          color: destructive
              ? Theme.of(context).colorScheme.error
              : context.emphasis.accent,
        ),
    title: Text(
      title,
      style: destructive
          ? TextStyle(color: Theme.of(context).colorScheme.error)
          : null,
    ),
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

  Future<void> _avatar({bool reset = false}) async {
    if (_busy) return;
    try {
      await _run(() async {
        int uploadId = 0;
        String? avatarTemplate;
        if (!reset) {
          final selected = await FilePicker.platform.pickFiles(
            type: FileType.image,
          );
          final path = selected?.files.single.path;
          if (path == null || !mounted) return;
          final confirmed = await showAppDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(context.l10n.forumPrefs_avatar),
              content: SizedBox(
                width: 240,
                height: 240,
                child: ClipOval(
                  child: Image.file(File(path), fit: BoxFit.cover),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(context.l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(context.l10n.common_save),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
          setState(() => _avatarBusy = true);
          final upload = await _service.uploadFile(path, uploadType: 'avatar');
          if (upload.id == null) throw StateError('Missing avatar upload ID');
          uploadId = upload.id!;
          avatarTemplate = upload.url;
        } else {
          avatarTemplate =
              widget.data.user['system_avatar_template'] as String?;
        }
        if (mounted) setState(() => _avatarBusy = true);
        await _service.pickPreferenceAvatar(
          _username,
          uploadId,
          reset ? 'system' : 'uploaded',
        );
        avatarTemplate ??= (await _service.getUser(_username)).avatarTemplate;
        if (avatarTemplate != null) {
          widget.data.user['avatar_template'] = avatarTemplate;
          await ref
              .read(currentUserProvider.notifier)
              .updateIdentity(
                _username,
                avatarTemplate: UrlHelper.resolveUrl(avatarTemplate),
              );
        }
        ToastService.showSuccess(S.current.forumPrefs_saved);
        // 网页重新加载会读取服务端生成的头像模板；原生端静默取得同一份资料。
        try {
          final user = await _service.getUser(_username);
          if (!mounted) return;
          await ref
              .read(currentUserProvider.notifier)
              .updateIdentity(_username, identity: user);
        } catch (_) {
          // 保存已成功，读取失败时沿用刚提交的头像，后续刷新再取得正式模板。
        }
        await widget.onChanged();
      });
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  List<Widget> _account() {
    final l = context.l10n;
    final user = widget.data.user;
    final current = ref.watch(currentUserProvider).value;
    final status = current?.id == user['id']
        ? current?.status
        : User.fromJson(user).status;
    final avatar = User.fromJson(user).getAvatarUrl(size: 144);
    return [
      _group(l.forumPrefs_avatar, [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SmartAvatar(
                imageUrl: avatar,
                radius: 32,
                fallbackText: _username,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (widget
                                .data
                                .settings['discourse_connect_overrides_avatar'] !=
                            true &&
                        widget.data.settings['auth_overrides_avatar'] !=
                            true) ...[
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _avatar,
                        icon: _avatarBusy
                            ? const LoadingSpinner(size: 18)
                            : const Icon(Symbols.edit_rounded, size: 18),
                        label: Text(
                          _avatarBusy
                              ? l.common_loading
                              : l.appearance_bgChange,
                        ),
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
        ),
      ]),
      if (widget.data.settings['enable_user_status'] == true)
        _group('', [
          _action(
            l.forumPrefs_status,
            _editStatus,
            subtitle: status?.description ?? l.forumPrefs_statusPrompt,
            leading: PreferenceStatusEmoji(
              status?.emoji ?? 'speech_balloon',
            ),
          ),
        ]),
      _group('', [
        _action(
          l.forumPrefs_title,
          _chooseTitle,
          icon: Symbols.badge_rounded,
          subtitle: user['title'] as String?,
        ),
        if (user['can_edit_username'] == true)
          _action(
            l.forumPrefs_username,
            _changeUsername,
            subtitle: _username,
            icon: Symbols.alternate_email_rounded,
          ),
      ]),
      _group(l.forumPrefs_email, [
        if (_emails == null && _error == null) const M3eLinearProgress(),
        if (_emails != null) ...[
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
          _action(
            l.forumPrefs_addEmail,
            () => _changeEmail(add: true),
            icon: Symbols.add_rounded,
          ),
      ]),
      if (widget.data.records('associated_accounts').isNotEmpty ||
          (widget.data.site['auth_providers'] as List? ?? []).isNotEmpty)
        _group(l.forumPrefs_connectedAccounts, [
          for (final account in widget.data.records('associated_accounts'))
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
        ]),
      _group(l.forumPrefs_accountData, [
        _action(
          l.forumPrefs_exportArchive,
          icon: Symbols.download_rounded,
          () => _run(() async {
            if (!await confirmPreferenceAction(
              context,
              l.forumPrefs_exportArchive,
              message: l.forumPrefs_exportArchiveHelp,
            )) {
              return;
            }
            await _service.exportPreferenceArchive();
            if (mounted) {
              ToastService.showSuccess(l.forumPrefs_archiveRequested);
            }
          }),
        ),
        if (widget.data.settings['enable_discourse_connect'] != true &&
            PreloadedDataService().currentUserSync?['can_delete_account'] ==
                true)
          _action(
            l.forumPrefs_deleteAccount,
            destructive: true,
            icon: Symbols.delete_outline_rounded,
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
      ]),
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
    final saved = await editUserStatus(
      context,
      ref,
      User.fromJson(widget.data.user),
    );
    if (saved == true) await widget.onChanged(reload: false);
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
        _group(l.forumPrefs_password, [
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
        ]),
        _group(l.forumPrefs_twoFactor, [
          _action(l.forumPrefs_addAuthenticator, _addTotp),
          if (_factors == null)
            _action(l.forumPrefs_authenticator, _loadFactors),
          if (_factors != null) ...[
            for (final factor in _factors!['totps'] as List? ?? [])
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
            for (final factor in _factors!['security_keys'] as List? ?? [])
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text('${factor['name']}'),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: l.common_edit,
                      onPressed: _busy
                          ? null
                          : () =>
                                _factorAction(factor as Map, securityKey: true),
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
        ]),
        if (widget.data.settings['enable_passkeys'] == true &&
            widget.data.records('user_passkeys').isNotEmpty)
          _group(l.forumPrefs_passkeys, [
            for (final passkey in widget.data.records('user_passkeys'))
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
          ]),
        _group('', [
          _action(
            l.forumPrefs_browserSecurity,
            icon: Symbols.open_in_browser_rounded,
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
        ]),
      ],
      _group(l.forumPrefs_sessions, [
        for (final session in widget.data.records('user_auth_tokens'))
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
      ]),
    ];
  }

  List<Widget> _users() => [
    if (widget.data.user['can_ignore_users'] == true)
      _group(context.l10n.forumPrefs_ignoredUsers, [
        for (final username
            in widget.data.user['ignored_usernames'] as List? ?? [])
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
            final selected = await showUserPickerSheet(
              context,
              title: context.l10n.forumPrefs_ignoredUsers,
              confirmLabel: (_) => context.l10n.common_confirm,
            );
            if (selected == null || selected.isEmpty || !mounted) return;
            final expiry = await showIgnoreDurationPicker(context);
            if (expiry == null || !mounted) return;
            try {
              for (final user in selected) {
                await _service.updateUserNotificationLevel(
                  user.username,
                  level: 'ignore',
                  expiringAt: expiry,
                );
              }
            } finally {
              await widget.onChanged();
            }
          }),
        ),
      ]),
  ];

  List<Widget> _apps() {
    final apps = widget.data.records('user_api_keys');
    return [
      if (apps.isEmpty)
        AppEmptyState(
          icon: const Icon(Symbols.apps_rounded),
          title: context.l10n.forumPrefs_empty,
          message: context.l10n.forumPrefs_appsDescription,
        ),
      if (apps.isNotEmpty)
        SegmentedCardGroup(
          children: [
            for (final app in apps)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
                          await _service.revokePreferenceApp(
                            id,
                            restore: restore,
                          );
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
          ],
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
      _group('', [
        ListTile(
          leading: const Icon(Symbols.calendar_month_rounded),
          title: Text(
            active
                ? context.l10n.forumPrefs_calendarActive
                : context.l10n.forumPrefs_calendarInactive,
          ),
          subtitle: Text(context.l10n.forumPrefs_calendarDescription),
        ),
      ]),
      if (urls.isNotEmpty)
        _group('', [
          for (final url in urls.entries)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: Text(
                url.key == 'bookmarks'
                    ? context.l10n.forumPrefs_bookmarks
                    : '${url.key}',
              ),
              subtitle: SelectableText('${url.value}'),
              trailing: IconButton(
                tooltip: context.l10n.common_copy,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: '${url.value}'));
                  if (mounted) {
                    ToastService.showSuccess(
                      context.l10n.common_copiedToClipboard,
                    );
                  }
                },
                icon: const Icon(Symbols.content_copy_rounded),
              ),
            ),
        ]),
      _group('', [
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
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_busy && (ModalRoute.isCurrentOf(context) ?? true))
        const M3eLinearProgress(),
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
