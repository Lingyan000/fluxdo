import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/s.dart';
import '../../models/forum_preferences.dart';
import '../../models/user.dart';
import '../../widgets/common/flair_badge.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../services/discourse/discourse_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/error_utils.dart';
import '../../utils/url_helper.dart';
import '../../utils/time_utils.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/common/tag_selection_sheet.dart';
import '../../widgets/common/cached_image.dart';
import '../chat/new_chat_sheet.dart';

Future<bool> confirmPreferenceAction(
  BuildContext context,
  String title, {
  String? message,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    ) ??
    false;

/// 提交在弹窗内执行，失败时保留输入，防止重新填写验证码或邮箱。
Future<bool> editPreferenceValue(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String? help,
  bool obscure = false,
  required Future<void> Function(String value) submit,
}) async =>
    await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PreferenceValueDialog(
        title: title,
        initialValue: initialValue,
        help: help,
        obscure: obscure,
        submit: submit,
      ),
    ) ??
    false;

class _PreferenceValueDialog extends StatefulWidget {
  const _PreferenceValueDialog({
    required this.title,
    required this.initialValue,
    required this.submit,
    this.help,
    this.obscure = false,
  });
  final String title;
  final String initialValue;
  final String? help;
  final bool obscure;
  final Future<void> Function(String) submit;
  @override
  State<_PreferenceValueDialog> createState() => _PreferenceValueDialogState();
}

class _PreferenceValueDialogState extends State<_PreferenceValueDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = widget.obscure ? _controller.text : _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = context.l10n.forumPrefs_required);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.submit(value);
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
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.help != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(widget.help!),
              ),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: widget.obscure,
              enableSuggestions: !widget.obscure,
              autocorrect: !widget.obscure,
              enabled: !_saving,
              decoration: InputDecoration(errorText: _error, errorMaxLines: 5),
              onSubmitted: (_) {
                if (!_saving) _save();
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? context.l10n.common_loading : context.l10n.common_save,
          ),
        ),
      ],
    ),
  );
}

Future<List<Object>?> selectPreferenceValues(
  BuildContext context, {
  required String title,
  required Map<Object, String> choices,
  required List<Object> selected,
  bool multiple = true,
  Widget Function(Object value)? leadingBuilder,
}) => showAppDialog<List<Object>>(
  context: context,
  builder: (_) => _PreferenceSelection(
    title: title,
    choices: choices,
    selected: selected,
    multiple: multiple,
    leadingBuilder: leadingBuilder,
  ),
);

class _PreferenceSelection extends StatefulWidget {
  const _PreferenceSelection({
    required this.title,
    required this.choices,
    required this.selected,
    required this.multiple,
    this.leadingBuilder,
  });
  final String title;
  final Map<Object, String> choices;
  final List<Object> selected;
  final bool multiple;
  final Widget Function(Object value)? leadingBuilder;
  @override
  State<_PreferenceSelection> createState() => _PreferenceSelectionState();
}

class _PreferenceSelectionState extends State<_PreferenceSelection> {
  late final _selected = widget.selected.toSet();
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final entries = widget.choices.entries
        .where(
          (item) => item.value.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        height:
            (widget.choices.length * 58.0 +
                    (widget.choices.length > 8 ? 64 : 0))
                .clamp(120, 400),
        child: Column(
          children: [
            if (widget.choices.length > 8)
              TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Symbols.search_rounded),
                  hintText: context.l10n.common_search,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            if (widget.choices.length > 8) const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final item = entries[index];
                  if (!widget.multiple) {
                    return ListTile(
                      leading: widget.leadingBuilder?.call(item.key),
                      title: Text(item.value),
                      selected: _selected.contains(item.key),
                      trailing: _selected.contains(item.key)
                          ? const Icon(Symbols.check_rounded)
                          : null,
                      onTap: () => Navigator.of(context).pop([item.key]),
                    );
                  }
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(item.value),
                    value: _selected.contains(item.key),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected.add(item.key);
                      } else {
                        _selected.remove(item.key);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.common_cancel),
        ),
        if (widget.multiple)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_selected.toList()),
            child: Text(context.l10n.common_confirm),
          ),
      ],
    );
  }
}

class PreferenceControl extends StatefulWidget {
  const PreferenceControl({
    super.key,
    required this.field,
    required this.value,
    required this.data,
    required this.onChanged,
    required this.onBusy,
  });
  final ForumPreferenceField field;
  final dynamic value;
  final ForumPreferences data;
  final ValueChanged<dynamic> onChanged;
  final ValueChanged<bool> onBusy;
  @override
  State<PreferenceControl> createState() => _PreferenceControlState();
}

class _PreferenceControlState extends State<PreferenceControl> {
  bool _uploading = false;
  int _imageRetry = 0;
  String? _error;

  Future<void> _pickUsers() async {
    final selected = await showUserPickerSheet(
      context,
      title: widget.field.label,
      confirmLabel: (_) => context.l10n.common_add,
    );
    if (selected == null || !mounted) return;
    final users = List<String>.from(widget.value as List);
    for (final user in selected) {
      if (!users.any(
        (name) => name.toLowerCase() == user.username.toLowerCase(),
      )) {
        users.add(user.username);
      }
    }
    widget.onChanged(users);
  }

  DateTime? get _birthday {
    final value = widget.value as String?;
    if (value == null || value.isEmpty) return null;
    // 生日是日历日期，补齐 UTC 标识以保持年月日，避免被设备时区移到前一天。
    final date = TimeUtils.parseUtcTime('${value}T00:00:00Z')?.toUtc();
    return date == null ? null : DateTime(date.year, date.month, date.day);
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final previous = _birthday;
    final first = DateTime(1900);
    final date = await showAppDialog<DateTime>(
      context: context,
      builder: (_) => DatePickerDialog(
        initialDate:
            previous != null &&
                !previous.isAfter(now) &&
                !previous.isBefore(first)
            ? previous
            : DateTime(now.year - 20, now.month, now.day),
        firstDate: first,
        lastDate: now,
        initialEntryMode: DatePickerEntryMode.calendarOnly,
      ),
    );
    if (date != null && mounted) {
      widget.onChanged(
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
      );
    }
  }

  Future<void> _pick() async {
    final field = widget.field;
    if (field.kind == ForumPreferenceKind.tags ||
        field.kind == ForumPreferenceKind.tagNames) {
      final selected = await AppBottomSheet.show<List<String>>(
        context: context,
        title: field.label,
        builder: (_) => TagSelectionSheet(
          availableTags: const [],
          selectedTags: List<String>.from(widget.value as List),
          maxTags: 1000,
        ),
      );
      if (selected != null && mounted) widget.onChanged(selected);
      return;
    }
    final choices = <Object, String>{...field.choices};
    if (field.kind == ForumPreferenceKind.categories) {
      for (final category
          in (widget.data.site['categories'] as List? ?? []).whereType<Map>()) {
        choices[category['id'] as Object] = '${category['name']}';
      }
    }
    final multiple =
        field.kind == ForumPreferenceKind.categories ||
        field.kind == ForumPreferenceKind.multiChoice;
    final values = multiple || field.kind == ForumPreferenceKind.theme
        ? List<Object>.from(widget.value as List)
        : [if (widget.value != null) widget.value as Object];
    if (field.kind == ForumPreferenceKind.flair) {
      if (!choices.containsKey(widget.value)) {
        values.clear();
        values.add(0);
      }
    } else {
      for (final value in values) {
        choices.putIfAbsent(value, () => '$value');
      }
    }
    final selected = await selectPreferenceValues(
      context,
      title: field.label,
      choices: choices,
      selected: values,
      multiple: multiple,
      leadingBuilder: field.kind == ForumPreferenceKind.flair
          ? (value) => _flairPreview(value)
          : null,
    );
    if (selected != null && mounted) {
      widget.onChanged(
        multiple || field.kind == ForumPreferenceKind.theme
            ? selected
            : selected.first,
      );
    }
  }

  Widget _flairPreview(Object? value, {bool withAvatar = false}) {
    final group = widget.data
        .records('groups')
        .where((group) => group['id'] == value)
        .firstOrNull;
    final url = group?['flair_url'] as String?;
    final name = group?['name'] as String?;
    final background = group?['flair_bg_color'] as String?;
    final color = group?['flair_color'] as String?;
    if (withAvatar) {
      final user = User.fromJson(widget.data.user);
      return AvatarWithFlair(
        avatar: SmartAvatar(
          imageUrl: user.getAvatarUrl(size: 96),
          radius: 24,
          fallbackText: user.username,
        ),
        flairUrl: url,
        flairName: name,
        flairBgColor: background,
        flairColor: color,
        flairSize: 22,
      );
    }
    return SizedBox(
      width: 28,
      height: 28,
      child: url == null || url.isEmpty
          ? const Icon(Symbols.block_rounded, size: 22)
          : FlairBadge(
              flairUrl: url,
              flairName: name,
              flairBgColor: background,
              flairColor: color,
              size: 28,
            ),
    );
  }

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    widget.onBusy(true);
    try {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );
      final path = selected?.files.single.path;
      if (path == null || !mounted) return;
      final result = await DiscourseService().uploadFile(
        path,
        uploadType: widget.field.uploadType!,
      );
      if (result.url == null || result.url!.isEmpty) {
        throw const FormatException('Missing image upload URL');
      }
      if (mounted) widget.onChanged(result.url!);
    } catch (error) {
      if (mounted) {
        setState(() => _error = ErrorUtils.getErrorInfo(error).message);
      }
    } finally {
      widget.onBusy(false);
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    switch (field.kind) {
      case ForumPreferenceKind.birthday:
        final birthday = _birthday;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Symbols.cake_rounded),
          title: Text(field.label),
          subtitle: Text(
            birthday == null
                ? context.l10n.forumPrefs_none
                : MaterialLocalizations.of(context).formatCompactDate(birthday),
          ),
          trailing: birthday == null
              ? const Icon(Symbols.chevron_right_rounded)
              : IconButton(
                  tooltip: context.l10n.common_clear,
                  onPressed: () => widget.onChanged(''),
                  icon: const Icon(Symbols.close_rounded),
                ),
          onTap: _pickBirthday,
        );
      case ForumPreferenceKind.usernames:
        final users = List<String>.from(widget.value as List);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(field.label),
              subtitle: users.isEmpty
                  ? Text(context.l10n.forumPrefs_none)
                  : null,
              trailing: IconButton(
                tooltip: context.l10n.common_add,
                icon: const Icon(Symbols.person_add_rounded),
                onPressed: _pickUsers,
              ),
              onTap: _pickUsers,
            ),
            if (users.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final username in users)
                    InputChip(
                      label: Text('@$username'),
                      onDeleted: () =>
                          widget.onChanged([...users]..remove(username)),
                    ),
                ],
              ),
          ],
        );
      case ForumPreferenceKind.toggle:
        return ListTileTheme.merge(
          contentPadding: EdgeInsets.zero,
          child: M3eSwitchListTile(
            title: Text(field.label),
            subtitle: field.help == null ? null : Text(field.help!),
            value: widget.value == true || widget.value == 'true',
            onChanged: widget.onChanged,
          ),
        );
      case ForumPreferenceKind.flair:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _flairPreview(widget.value, withAvatar: true),
              title: Text(field.label),
              subtitle: Text(
                field.choices[widget.value] ?? context.l10n.forumPrefs_none,
              ),
              trailing: const Icon(Symbols.expand_more_rounded),
              onTap: _pick,
            ),
            if (field.help != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  field.help!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      case ForumPreferenceKind.choice ||
          ForumPreferenceKind.categories ||
          ForumPreferenceKind.tags ||
          ForumPreferenceKind.tagNames ||
          ForumPreferenceKind.theme ||
          ForumPreferenceKind.multiChoice:
        final values = widget.value is List
            ? widget.value as List
            : [if (widget.value != null) widget.value];
        final labels = <Object, String>{
          ...field.choices,
          if (field.kind == ForumPreferenceKind.categories)
            for (final category
                in (widget.data.site['categories'] as List? ?? [])
                    .whereType<Map>())
              category['id'] as Object: '${category['name']}',
        };
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(field.label),
          subtitle: Text(
            values.isEmpty
                ? context.l10n.forumPrefs_none
                : values.map((value) => labels[value] ?? '$value').join(', '),
          ),
          trailing: const Icon(Symbols.chevron_right_rounded),
          onTap: _pick,
        );
      case ForumPreferenceKind.image:
        final hasImage = (widget.value as String).isNotEmpty;
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(field.label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            AspectRatio(
              key: ValueKey('image-preview-${field.id}'),
              aspectRatio: 2,
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: RoundedSuperellipseBorder(
                  borderRadius: context.shapes.borderRadius(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: hasImage
                    ? CachedImage(
                        key: ValueKey((widget.value, _imageRetry)),
                        url: UrlHelper.resolveUrl(widget.value as String),
                        fit: BoxFit.contain,
                        placeholder: (_) =>
                            const Center(child: LoadingSpinner(size: 24)),
                        errorBuilder: (_, _, _) => Center(
                          child: TextButton.icon(
                            onPressed: () => setState(() => _imageRetry++),
                            icon: const Icon(Symbols.refresh_rounded, size: 20),
                            label: Text(context.l10n.common_loadFailedTapRetry),
                          ),
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Symbols.add_photo_alternate_rounded,
                              size: 28,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              context.l10n.forumPrefs_noBackground,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: _uploading ? null : _upload,
                      icon: _uploading
                          ? const LoadingSpinner(size: 18)
                          : Icon(
                              hasImage
                                  ? Symbols.edit_rounded
                                  : Symbols.add_photo_alternate_rounded,
                              size: 18,
                            ),
                      label: Text(
                        _uploading
                            ? context.l10n.common_loading
                            : hasImage
                            ? context.l10n.appearance_bgChange
                            : context.l10n.forumPrefs_upload,
                      ),
                    ),
                  ),
                ),
                if (hasImage)
                  IconButton(
                    tooltip: context.l10n.common_remove,
                    onPressed: _uploading
                        ? null
                        : () {
                            setState(() => _error = null);
                            widget.onChanged('');
                          },
                    icon: const Icon(Symbols.delete_outline_rounded, size: 20),
                  ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        );
      case ForumPreferenceKind.schedule:
        return _ScheduleControl(
          value: Map<String, dynamic>.from(widget.value as Map),
          onChanged: widget.onChanged,
          label: field.label,
          help: field.help,
        );
      case ForumPreferenceKind.text || ForumPreferenceKind.multiline:
        return TextFormField(
          initialValue: widget.value?.toString() ?? '',
          keyboardType: field.key == 'website' ? TextInputType.url : null,
          decoration: InputDecoration(
            labelText: field.label,
            helperText: field.help,
            helperMaxLines: 3,
            alignLabelWithHint: true,
            filled: false,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ).withoutBorder(),
          minLines: field.kind == ForumPreferenceKind.multiline ? 4 : 1,
          maxLines: field.kind == ForumPreferenceKind.multiline ? 10 : 1,
          validator: (value) {
            if (field.required && (value == null || value.trim().isEmpty)) {
              return context.l10n.forumPrefs_required;
            }
            if (field.key == 'timezone' &&
                value != null &&
                value.isNotEmpty &&
                !tz.timeZoneDatabase.locations.containsKey(value)) {
              return context.l10n.forumPrefs_invalidValue;
            }
            return null;
          },
          onChanged: widget.onChanged,
        );
    }
  }
}

class _ScheduleControl extends StatelessWidget {
  const _ScheduleControl({
    required this.value,
    required this.onChanged,
    required this.label,
    this.help,
  });
  final Map<String, dynamic> value;
  final ValueChanged<dynamic> onChanged;
  final String label;
  final String? help;
  String _time(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
  Future<void> _edit(BuildContext context, int day, bool start) async {
    final key = 'day_${day}_${start ? 'start' : 'end'}_time';
    final startTime = (value['day_${day}_start_time'] as num?)?.toInt() ?? 0;
    final choices = <Object, String>{
      if (start) -1: context.l10n.forumPrefs_none,
    };
    for (
      int minute = start ? 0 : startTime + 30;
      minute <= (start ? 1410 : 1440);
      minute += 30
    ) {
      choices[minute] = _time(minute);
    }
    final selected = await selectPreferenceValues(
      context,
      title: label,
      choices: choices,
      selected: [value[key] ?? 0],
      multiple: false,
    );
    if (selected == null || !context.mounted) return;
    final next = {...value, key: selected.single};
    if (start &&
        (selected.single as int) >=
            ((next['day_${day}_end_time'] as num?)?.toInt() ?? 0)) {
      next['day_${day}_end_time'] = (selected.single as int) + 30;
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTileTheme.merge(
        contentPadding: EdgeInsets.zero,
        child: M3eSwitchListTile(
          title: Text(label),
          subtitle: help == null ? null : Text(help!),
          value: value['enabled'] == true,
          onChanged: (enabled) => onChanged({...value, 'enabled': enabled}),
        ),
      ),
      if (value['enabled'] == true)
        for (int day = 0; day < DateTime.daysPerWeek; day++)
          Row(
            children: [
              Expanded(
                child: Text(
                  MaterialLocalizations.of(context)
                      .narrowWeekdays[(day + 1) % 7],
                ),
              ),
              TextButton(
                onPressed: () => _edit(context, day, true),
                child: Text(
                  value['day_${day}_start_time'] == -1
                      ? context.l10n.forumPrefs_none
                      : _time(
                          (value['day_${day}_start_time'] as num?)?.toInt() ??
                              0,
                        ),
                ),
              ),
              const Text('–'),
              TextButton(
                onPressed: value['day_${day}_start_time'] == -1
                    ? null
                    : () => _edit(context, day, false),
                child: Text(
                  _time(
                    (value['day_${day}_end_time'] as num?)?.toInt() ?? 1440,
                  ),
                ),
              ),
            ],
          ),
    ],
  );
}
