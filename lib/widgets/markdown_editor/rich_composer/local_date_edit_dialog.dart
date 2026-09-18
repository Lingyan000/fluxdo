/// 本地日期编辑对话框(官方 local-dates-create modal 的精简版):
/// 日期 + 可选时间 + 时区 + 倒计时开关。
///
/// 用途:
/// - 插入菜单「日期时间」→ 空初值弹本对话框 → 确认插入 date 原子;
/// - 编辑器内单击 date chip → 现值弹本对话框 → 确认 replaceAtomAt。
///
/// controller 归本 State 所有(对话框退场动画期存活 —— 外部 pop 后
/// 立即 dispose 会崩,见 rich_composer_editor 的 _MarkdownInputDialog)。
library;

import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show LocalDateRun;

import '../../../utils/dialog_utils.dart';

/// 弹日期编辑对话框。返回新 [LocalDateRun];取消返回 null。
Future<LocalDateRun?> showLocalDateEditDialog(
  BuildContext context, {
  LocalDateRun? initial,
}) {
  return showAppDialog<LocalDateRun>(
    context: context,
    builder: (ctx) => _LocalDateEditDialog(initial: initial),
  );
}

class _LocalDateEditDialog extends StatefulWidget {
  const _LocalDateEditDialog({this.initial});

  final LocalDateRun? initial;

  @override
  State<_LocalDateEditDialog> createState() => _LocalDateEditDialogState();
}

class _LocalDateEditDialogState extends State<_LocalDateEditDialog> {
  late DateTime _date;
  TimeOfDay? _time;
  late final TextEditingController _timezoneController;
  late bool _countdown;
  bool _timeChanged = false;
  late final TextEditingController _endDateController;
  late final TextEditingController _endTimeController;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    // 日期 token 是无时区的日历日期，不按 UTC 时间戳解析。
    final parts = (init?.date ?? '').split('-').map(int.tryParse).toList();
    _date = parts.length == 3 && parts.every((v) => v != null)
        ? DateTime(parts[0]!, parts[1]!, parts[2]!)
        : DateTime.now();
    _endDateController = TextEditingController(text: init?.endDate);
    _endTimeController = TextEditingController(text: init?.endTime);
    final t = init?.time;
    if (t != null && t.length >= 5) {
      final h = int.tryParse(t.substring(0, 2));
      final m = int.tryParse(t.substring(3, 5));
      if (h != null && m != null) _time = TimeOfDay(hour: h, minute: m);
    }
    _timezoneController = TextEditingController(
      // 默认作者时区:官方 modal 同款(取系统时区名)
      text: init == null ? DateTime.now().timeZoneName : init.timezone ?? '',
    );
    _countdown = init?.countdown ?? false;
  }

  @override
  void dispose() {
    _timezoneController.dispose();
    _endDateController.dispose();
    _endTimeController.dispose();
    super.dispose();
  }

  String get _dateStr => '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

  String? get _timeStr => !_timeChanged && widget.initial != null
      ? widget.initial!.time
      : _time == null
      ? null
      : '${_time!.hour.toString().padLeft(2, '0')}:'
          '${_time!.minute.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 12, minute: 0),
    );
    if (picked != null) setState(() { _time = picked; _timeChanged = true; });
  }

  bool _validEndDate() {
    final value = _endDateController.text.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final parts = value.split('-').map(int.parse).toList();
    final date = DateTime(parts[0], parts[1], parts[2]);
    return date.year == parts[0] && date.month == parts[1] && date.day == parts[2];
  }

  LocalDateRun _build() {
    final init = widget.initial;
    final tz = _timezoneController.text.trim();
    return LocalDateRun(
      date: _dateStr,
      time: _timeStr,
      timezone: tz.isEmpty ? null : tz,
      // 未在本对话框暴露的字段原样保留(format/timezones/…)
      timezones: init?.timezones ?? const [],
      format: init?.format,
      displayedTimezone: init?.displayedTimezone,
      countdown: _countdown,
      countdownRaw: _countdown == init?.countdown ? init?.countdownRaw : (_countdown ? 'true' : 'false'),
      recurring: init?.recurring,
      endDate: init?.endDate == null ? null : _endDateController.text.trim(),
      endTime: _endTimeController.text.trim().isEmpty ? null : _endTimeController.text.trim(),
      range: init?.range,
      // 编辑态显示文本:无服务端预渲染,拼本地可读串
      fallbackText:
          _timeStr == null ? _dateStr : '$_dateStr $_timeStr',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '插入日期时间' : '编辑日期时间'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_outlined, size: 16),
                label: Text(_dateStr),
                onPressed: _pickDate,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.schedule_outlined, size: 16),
                label: Text(_timeStr ?? '全天'),
                onPressed: _pickTime,
              ),
            ),
            if (_time != null)
              IconButton(
                tooltip: '清除时间',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => setState(() { _time = null; _timeChanged = true; }),
              ),
          ]),
          if (widget.initial?.endDate != null) ...[
            const SizedBox(height: 12),
            TextField(controller: _endDateController, decoration: const InputDecoration(labelText: '结束日期（YYYY-MM-DD）')),
            TextField(controller: _endTimeController, decoration: const InputDecoration(labelText: '结束时间（HH:mm，可留空）')),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _timezoneController,
            decoration: const InputDecoration(
              labelText: '时区',
              hintText: 'Asia/Shanghai',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: _countdown,
            onChanged: (v) => setState(() => _countdown = v ?? false),
            title: const Text('倒计时', style: TextStyle(fontSize: 14)),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (widget.initial?.endDate != null &&
                (!_validEndDate() ||
                 (_endTimeController.text.trim().isNotEmpty && !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$').hasMatch(_endTimeController.text.trim())))) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写有效的结束日期和时间')));
              return;
            }
            Navigator.pop(context, _build());
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}
