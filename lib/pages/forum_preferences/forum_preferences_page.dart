import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../settings/settings_model.dart';
import '../../widgets/settings/settings_group_page.dart';
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
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SegmentedCardGroup(
          children: [
            for (final section in _sections)
              ListTile(
                key: ValueKey(section),
                leading: Icon(
                  preferenceSectionIcon(section),
                  color: context.emphasis.accent,
                ),
                selected: _section == section,
                selectedTileColor: context.emphasis.selected.withValues(
                  alpha: 0.1,
                ),
                title: Text(preferenceSectionLabel(section, context.l10n)),
                trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
                onTap: _saving || _operationBusy
                    ? null
                    : () => _select(section),
              ),
          ],
        ),
      ),
      if (_sections.isEmpty)
        AppEmptyState(
          icon: const Icon(Symbols.search_rounded),
          title: context.l10n.search_noResults,
        ),
    ],
  );

  Widget _editor({bool wide = false}) {
    final data = _data!;
    final section = _section!;
    final draft = _draft!;
    return Column(
      children: [
        if (wide)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          preferenceSectionIcon(section),
                          color: context.emphasis.accent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            preferenceSectionLabel(section, context.l10n),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (draft.fields.isNotEmpty) _saveButton(),
                      ],
                    ),
                    if (_saveError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _saveError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: AbsorbPointer(
            absorbing: _saving || _operationBusy,
            child: Form(
              key: _formKey,
              child: SettingsGroupPage(
                key: ValueKey(section),
                title: preferenceSectionLabel(section, context.l10n),
                embedded: true,
                maxContentWidth: 720,
                groupsBuilder: (context) => [
                  if (_loadError != null)
                    SettingsGroup(
                      title: '',
                      icon: Symbols.error_rounded,
                      items: [
                        ActionModel(
                          id: 'forum-reload',
                          title: ErrorUtils.getErrorInfo(_loadError!).message,
                          icon: Symbols.refresh_rounded,
                          onTap: (_, _) => _load(preserveDraft: true),
                        ),
                      ],
                    ),
                  SettingsGroup(
                    title: '',
                    icon: preferenceSectionIcon(section),
                    items: [
                      if (section == ForumPreferenceSection.interface)
                        CustomModel(
                          id: 'forum-interface-help',
                          title: '',
                          builder: (_, _) => Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(context.l10n.forumPrefs_interfaceHelp),
                          ),
                        ),
                      for (final field in draft.fields)
                        if (field.kind == ForumPreferenceKind.toggle)
                          SwitchModel(
                            id: field.id,
                            title: field.label,
                            subtitle: field.help,
                            icon: preferenceSectionIcon(section),
                            getValue: (_) =>
                                draft.values[field.id] == true ||
                                draft.values[field.id] == 'true',
                            onChanged: (_, value) => setState(() {
                              draft.update(field, value);
                              _saveError = null;
                            }),
                          )
                        else
                          CustomModel(
                            id: field.id,
                            title: field.label,
                            builder: (_, _) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
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
                                  if (mounted) {
                                    setState(() => _operationBusy = busy);
                                  }
                                },
                              ),
                            ),
                          ),
                    ],
                  ),
                  SettingsGroup(
                    title: '',
                    icon: preferenceSectionIcon(section),
                    wrapInCard: false,
                    items: [
                      CustomModel(
                        id: 'forum-actions-${section.name}',
                        title: '',
                        builder: (_, _) => PreferenceActions(
                          key: ValueKey('$_username/${section.name}'),
                          section: section,
                          data: data,
                          onChanged: _afterAction,
                          onBusy: (busy) {
                            if (mounted) setState(() => _operationBusy = busy);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!wide && draft.fields.isNotEmpty)
          PageBackdrop(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
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
                      _saveButton(),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _saveButton() => FilledButton.icon(
    onPressed: _draft?.dirty == true && !_saving && !_operationBusy
        ? _save
        : null,
    icon: _saving
        ? const LoadingSpinner(size: 18)
        : const Icon(Symbols.check_rounded, size: 18),
    label: Text(
      _saving ? context.l10n.common_loading : context.l10n.common_save,
    ),
  );

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
            body = AppEmptyState(
              icon: const Icon(Symbols.lock_rounded),
              title: context.l10n.forumPrefs_readOnly,
            );
          } else if (wide) {
            body = Row(
              children: [
                SizedBox(width: 280, child: _navigation()),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _section == null
                      ? AppEmptyState(
                          icon: const Icon(Symbols.settings_rounded),
                          title: context.l10n.userProfile_forumPreferences,
                        )
                      : _editor(wide: true),
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
                wide || _section == null
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
