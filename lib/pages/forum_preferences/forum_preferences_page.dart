import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/forum_preferences.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../../utils/error_utils.dart';
import '../../widgets/common/error_view.dart';
import 'preference_actions.dart';
import 'preference_controls.dart';
import 'preference_fields.dart';

export '../../models/forum_preferences.dart' show ForumPreferenceSection;

class ForumPreferencesPage extends StatefulWidget {
  const ForumPreferencesPage({
    super.key,
    required this.username,
    this.initialSection,
  });
  final String username;
  final ForumPreferenceSection? initialSection;
  @override
  State<ForumPreferencesPage> createState() => _ForumPreferencesPageState();
}

class _ForumPreferencesPageState extends State<ForumPreferencesPage> {
  final _service = DiscourseService();
  final _formKey = GlobalKey<FormState>();
  late String _username = widget.username;
  late ForumPreferenceSection? _section = widget.initialSection;
  ForumPreferences? _data;
  ForumPreferenceDraft? _draft;
  Object? _loadError;
  String? _saveError;
  bool _loading = true;
  bool _saving = false;
  bool _operationBusy = false;
  bool _changed = false;
  bool _allowPop = false;
  int _revision = 0;
  int _loadGeneration = 0;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool preserveDraft = false}) async {
    final generation = ++_loadGeneration;
    try {
      final data = await _service.getForumPreferences(_username);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        final previous = _draft;
        _data = data;
        _loadError = null;
        _loading = false;
        _createDraft();
        if (preserveDraft && previous != null && _draft != null) {
          for (final field in previous.fields.where(previous.isChanged)) {
            if (_draft!.values.containsKey(field.id)) {
              _draft!.values[field.id] = previous.values[field.id];
            }
          }
        }
      });
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loadError = error;
          _loading = false;
        });
      }
    }
  }

  void _createDraft() {
    final section = _section;
    final data = _data;
    _draft = section == null || data == null
        ? null
        : ForumPreferenceDraft(
            preferenceFields(section, data, context.l10n),
            data.user,
          );
    _revision++;
    _saveError = null;
  }

  Future<bool> _canLeave() async {
    if (_saving || _operationBusy) return false;
    if (_draft?.dirty != true) return true;
    return confirmPreferenceAction(
      context,
      context.l10n.forumPrefs_leaveTitle,
      message: context.l10n.forumPrefs_leaveBody,
    );
  }

  Future<void> _select(ForumPreferenceSection section) async {
    if (_section == section || !await _canLeave() || !mounted) return;
    setState(() {
      _section = section;
      _createDraft();
    });
  }

  Future<void> _back({bool exit = false}) async {
    if (!await _canLeave() || !mounted) return;
    if (!exit && _section != null && widget.initialSection == null) {
      setState(() {
        _section = null;
        _createDraft();
      });
      return;
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(_changed ? _username : null);
    });
  }

  Future<void> _save() async {
    final draft = _draft;
    if (_saving ||
        _operationBusy ||
        draft == null ||
        !draft.dirty ||
        !_formKey.currentState!.validate()) {
      return;
    }
    for (final field in draft.fields.where((field) => field.required)) {
      final value = draft.values[field.id];
      if (value == null ||
          value == '' ||
          value == false ||
          (value is List && value.isEmpty)) {
        setState(
          () => _saveError =
              '${field.label}\n${context.l10n.forumPrefs_required}',
        );
        return;
      }
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await _service.saveForumPreferences(_username, draft.payload);
      if (!mounted) return;
      _loadGeneration++;
      // PUT 已成功就推进本地基线，后续读取失败不会把成功保存当成失败。
      for (final field in draft.fields.where(draft.isChanged).toList()) {
        final value = draft.values[field.id];
        if (field.container == null) {
          draft.user[field.key] = value;
        } else {
          (draft.user.putIfAbsent(field.container!, () => <String, dynamic>{})
                  as Map)[field.key] =
              value;
        }
      }
      setState(() => _changed = true);
      ToastService.showSuccess(context.l10n.forumPrefs_saved);
    } catch (error) {
      if (mounted) {
        setState(() => _saveError = ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _afterAction({String? username, bool signedOut = false}) async {
    if (!mounted) return;
    _changed = true;
    if (username != null) _username = username;
    if (signedOut) {
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(_username);
      });
      return;
    }
    await _load(preserveDraft: true);
  }

  List<ForumPreferenceSection> get _sections =>
      ForumPreferenceSection.values.where((section) {
        if (section == ForumPreferenceSection.chat &&
            _data?.settings['chat_enabled'] != true) {
          return false;
        }
        final query = _query.trim().toLowerCase();
        return preferenceSectionLabel(
              section,
              context.l10n,
            ).toLowerCase().contains(query) ||
            (_data != null &&
                preferenceFields(
                  section,
                  _data!,
                  context.l10n,
                ).any((field) => field.label.toLowerCase().contains(query)));
      }).toList();

  Widget _navigation() => ListView(
    padding: const EdgeInsets.symmetric(vertical: 8),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: TextField(
          decoration: InputDecoration(
            hintText: context.l10n.forumPrefs_search,
            prefixIcon: const Icon(Symbols.search_rounded),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
      ),
      for (final section in _sections)
        ListTile(
          selected: _section == section,
          title: Text(preferenceSectionLabel(section, context.l10n)),
          trailing: const Icon(Symbols.chevron_right_rounded),
          onTap: _saving || _operationBusy ? null : () => _select(section),
        ),
    ],
  );

  Widget _editor() {
    final data = _data!;
    final section = _section!;
    final draft = _draft!;
    return Column(
      children: [
        Expanded(
          child: AbsorbPointer(
            absorbing: _saving || _operationBusy,
            child: Form(
              key: _formKey,
              child: ListView(
                key: ValueKey(section),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  if (section == ForumPreferenceSection.interface)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Text(context.l10n.forumPrefs_interfaceHelp),
                    ),
                  if (_loadError != null)
                    ListTile(
                      title: Text(ErrorUtils.getErrorInfo(_loadError!).message),
                      trailing: IconButton(
                        tooltip: context.l10n.common_retry,
                        onPressed: () => _load(preserveDraft: true),
                        icon: const Icon(Symbols.refresh_rounded),
                      ),
                    ),
                  for (final field in draft.fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: PreferenceControl(
                        key: ValueKey('$_revision/${field.id}'),
                        field: field,
                        value: draft.values[field.id],
                        data: data,
                        onChanged: (value) => setState(() {
                          draft.update(field, value);
                          _saveError = null;
                        }),
                        onBusy: (busy) {
                          if (mounted) setState(() => _operationBusy = busy);
                        },
                      ),
                    ),
                  PreferenceActions(
                    key: ValueKey('$_username/${section.name}'),
                    section: section,
                    data: data,
                    onChanged: _afterAction,
                    onBusy: (busy) {
                      if (mounted) setState(() => _operationBusy = busy);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        if (draft.fields.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_saveError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _saveError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: draft.dirty && !_saving && !_operationBusy
                      ? _save
                      : null,
                  child: Text(
                    _saving
                        ? context.l10n.common_loading
                        : context.l10n.common_save,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<String>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          Widget body;
          if (_loading) {
            body = const Center(child: LoadingSpinner());
          } else if (_data == null) {
            body = ErrorView(
              error: _loadError!,
              onRetry: () {
                setState(() => _loading = true);
                _load();
              },
            );
          } else if (!_data!.canEdit) {
            body = Center(child: Text(context.l10n.forumPrefs_readOnly));
          } else if (wide) {
            body = Row(
              children: [
                SizedBox(width: 250, child: _navigation()),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _section == null
                      ? Center(
                          child: Text(
                            context.l10n.userProfile_forumPreferences,
                          ),
                        )
                      : _editor(),
                ),
              ],
            );
          } else {
            body = _section == null ? _navigation() : _editor();
          }
          return Scaffold(
            appBar: AppBar(
              leading: BackButton(onPressed: () => _back(exit: wide)),
              title: Text(
                _section == null
                    ? context.l10n.userProfile_forumPreferences
                    : preferenceSectionLabel(_section!, context.l10n),
              ),
            ),
            body: SafeArea(top: false, child: body),
          );
        },
      ),
    );
  }
}
