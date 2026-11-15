import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/user.dart';
import '../../providers/core_providers.dart';
import '../../services/toast_service.dart';
import '../../widgets/common/smart_avatar.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/error_utils.dart';
import '../../utils/time_utils.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../widgets/markdown_editor/emoji_picker.dart';
import 'preference_controls.dart';

Future<bool?> editUserStatus(BuildContext context, WidgetRef ref, User user) {
  final current = ref.read(currentUserProvider).value;
  final status = current?.id == user.id ? current?.status : user.status;
  final notifier = ref.read(currentUserProvider.notifier);
  final service = ref.read(discourseServiceProvider);
  return showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatusDialog(
      user: user,
      status: status == null
          ? {}
          : {
              'description': status.description,
              'emoji': status.emoji,
              'ends_at': status.endsAt?.toUtc().toIso8601String(),
            },
      submit: (value) async {
        await service.saveUserStatus(value);
        await notifier.updateIdentity(
          user.username,
          status: value == null ? null : UserStatus.fromJson(value),
          clearStatus: value == null,
        );
        ToastService.showSuccess(S.current.forumPrefs_saved);
      },
    ),
  );
}

class PreferenceStatusEmoji extends StatelessWidget {
  const PreferenceStatusEmoji(this.name, {super.key, this.size = 24});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => Image(
    image: emojiImageProvider(EmojiHandler().getEmojiUrl(name)),
    width: size,
    height: size,
    frameBuilder: (_, child, frame, synchronous) => synchronous || frame != null
        ? child
        : Icon(Symbols.mood_rounded, size: size),
    errorBuilder: (_, _, _) => Icon(Symbols.mood_rounded, size: size),
  );
}

class StatusDialog extends StatefulWidget {
  const StatusDialog({
    super.key,
    required this.status,
    required this.submit,
    this.user,
  });

  final User? user;
  final Map<String, dynamic> status;
  final Future<void> Function(Map<String, dynamic>?) submit;

  @override
  State<StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<StatusDialog> {
  late final _description = TextEditingController(
    text: widget.status['description'] as String? ?? '',
  );
  late String _emoji = (widget.status['emoji'] as String?)?.isNotEmpty == true
      ? widget.status['emoji'] as String
      : 'speech_balloon';
  late int _expiry = widget.status['ends_at'] == null ? 0 : -1;
  DateTime? _customExpiry;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickEmoji() async {
    FocusScope.of(context).unfocus();
    final selected = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 400,
          height: 440,
          child: EmojiPicker(
            compact: true,
            inlineSearch: true,
            onEmojiSelected: (emoji) =>
                Navigator.of(dialogContext).pop(emoji.name),
          ),
        ),
      ),
    );
    if (selected != null && mounted) setState(() => _emoji = selected);
  }

  Map<Object, String> get _expiryChoices => {
    if (widget.status['ends_at'] != null)
      -1: TimeUtils.formatDetailTime(
        TimeUtils.parseUtcTime(widget.status['ends_at'] as String?),
      ),
    0: context.l10n.forumPrefs_noExpiry,
    3600: context.l10n.forumPrefs_hour1,
    7200: context.l10n.forumPrefs_hours2,
    86400: context.l10n.forumPrefs_day1,
    -2: context.l10n.forumPrefs_custom,
  };

  Future<void> _pickExpiry() async {
    final selected = await selectPreferenceValues(
      context,
      title: context.l10n.forumPrefs_statusExpiry,
      choices: _expiryChoices,
      selected: [_expiry],
      multiple: false,
    );
    if (selected == null || !mounted) return;
    final expiry = selected.single as int;
    if (expiry == -2) {
      final now = DateTime.now();
      final initial = _customExpiry ?? now.add(const Duration(hours: 1));
      final day = await showAppDialog<DateTime>(
        context: context,
        builder: (_) => DatePickerDialog(
          initialDate: initial.isBefore(now) ? now : initial,
          firstDate: now,
          lastDate: DateTime(now.year + 10),
          initialEntryMode: DatePickerEntryMode.calendarOnly,
        ),
      );
      if (day == null || !mounted) return;
      final time = await showAppDialog<TimeOfDay>(
        context: context,
        builder: (_) =>
            TimePickerDialog(initialTime: TimeOfDay.fromDateTime(initial)),
      );
      if (time == null || !mounted) return;
      final end = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      );
      if (!end.isAfter(DateTime.now())) {
        setState(() => _error = context.l10n.forumPrefs_futureTime);
        return;
      }
      _customExpiry = end;
    }
    setState(() {
      _expiry = expiry;
      _error = null;
    });
  }

  Future<void> _save({bool clear = false}) async {
    if (_saving) return;
    if (!clear && (_description.text.trim().isEmpty || _emoji.isEmpty)) return;
    if (!clear && _expiry == -2 && !_customExpiry!.isAfter(DateTime.now())) {
      setState(() => _error = context.l10n.forumPrefs_futureTime);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final endsAt = switch (_expiry) {
        -1 => widget.status['ends_at'],
        -2 => _customExpiry!.toUtc().toIso8601String(),
        0 => null,
        _ =>
          DateTime.now()
              .toUtc()
              .add(Duration(seconds: _expiry))
              .toIso8601String(),
      };
      await widget.submit(
        clear
            ? null
            : {
                'description': _description.text.trim(),
                'emoji': _emoji,
                'ends_at': endsAt,
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
  Widget build(BuildContext context) {
    final l = context.l10n;
    final presets = {
      'headphones': l.forumPrefs_statusFocus,
      'coffee': l.forumPrefs_statusBreak,
      'spiral_calendar': l.forumPrefs_statusMeeting,
      'palm_tree': l.forumPrefs_statusAway,
    };
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: Text(l.forumPrefs_status),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: AbsorbPointer(
              absorbing: _saving,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.user != null) ...[
                    Row(
                      children: [
                        SmartAvatar(
                          imageUrl: widget.user!.getAvatarUrl(size: 96),
                          radius: 28,
                          fallbackText: widget.user!.username,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.user!.name ?? widget.user!.username,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  PreferenceStatusEmoji(_emoji, size: 20),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _description.text.trim().isEmpty
                                          ? l.forumPrefs_statusPrompt
                                          : _description.text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                  TextField(
                    controller: _description,
                    maxLength: 100,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: l.forumPrefs_statusPrompt,
                      prefixIcon: IconButton(
                        tooltip: l.forumPrefs_statusEmoji,
                        onPressed: _pickEmoji,
                        icon: PreferenceStatusEmoji(_emoji),
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final preset in presets.entries)
                        ActionChip(
                          avatar: PreferenceStatusEmoji(preset.key, size: 20),
                          label: Text(preset.value),
                          onPressed: () => setState(() {
                            _emoji = preset.key;
                            _description.text = preset.value;
                            _error = null;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SegmentedCardGroup(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: Text(l.forumPrefs_statusExpiry),
                        subtitle: Text(
                          _expiry == -2
                              ? TimeUtils.formatDetailTime(_customExpiry)
                              : _expiryChoices[_expiry]!,
                        ),
                        trailing: const Icon(Symbols.chevron_right_rounded),
                        onTap: _pickExpiry,
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
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
        actions: [
          if (widget.status.isNotEmpty)
            TextButton(
              onPressed: _saving ? null : () => _save(clear: true),
              child: Text(l.common_remove),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: Text(l.common_cancel),
          ),
          FilledButton(
            onPressed: _saving || _description.text.trim().isEmpty
                ? null
                : _save,
            child: _saving
                ? const LoadingSpinner(size: 20)
                : Text(l.common_save),
          ),
        ],
      ),
    );
  }
}
