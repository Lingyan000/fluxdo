/// 投票构建器对话框(官方 poll-ui-builder 精简对齐版):
/// 类型三选(单选/多选/数字评分)+ 标题 + 选项列表 + 高级选项
/// (结果可见性 / 公开投票人 / 图表类型 / 自动关闭时间)。
///
/// 产出 [PollSpec],由调用方 `toBBCode()` 后插入正文 —— 创建投票
/// 本质是往 raw 里写 `[poll ...]...[/poll]`,发帖接口透明带过去。
///
/// controller 归本 State 所有(pop 后宿主立即 dispose 会撞退场动画,
/// 见 local_date_edit_dialog 同款注释)。
library;

import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../utils/dialog_utils.dart';
import '../../utils/time_utils.dart';

/// 投票类型(对齐 Discourse poll 插件;ranked_choice 暂不支持)。
const kPollTypeRegular = 'regular';
const kPollTypeMultiple = 'multiple';
const kPollTypeNumber = 'number';

/// 结果可见性(对齐官方 results 枚举)。
const kPollResults = [
  ('always', '始终可见'),
  ('on_vote', '投票后可见'),
  ('on_close', '关闭后可见'),
  ('staff_only', '仅管理人员可见'),
];

/// 对话框结果:一份可序列化为 BBCode 的投票规格。
class PollSpec {
  const PollSpec({
    required this.type,
    required this.results,
    required this.public,
    required this.chartType,
    required this.title,
    required this.options,
    this.min,
    this.max,
    this.step,
    this.close,
    this.extraAttrs = const {},
  });

  final String type;
  final String results;
  final bool public;
  final String chartType; // 'bar' | 'pie'(number 型不输出)
  final String title; // 空 = 不输出标题行
  final List<String> options; // number 型忽略
  final int? min;
  final int? max;
  final int? step; // 仅 number
  final DateTime? close; // 本地时间,输出转 UTC ISO8601

  /// 表单未建模的属性(name/status/groups/dynamic…):编辑已有投票时
  /// 原样带回,避免表单一轮编辑丢属性。
  final Map<String, String> extraAttrs;

  /// 表单托管的属性键(小写),写回时从 extraAttrs 排除
  static const _managedKeys = {
    'type', 'results', 'public', 'charttype', 'min', 'max', 'step', 'close',
  };

  /// 从 `[poll ...]...[/poll]` BBCode 反解析(编辑已有投票的表单预填)。
  /// 解析不了(结构异常)返回 null,调用方回退源码编辑。
  static PollSpec? tryParse(String source) {
    final m = RegExp(
      r'^\s*\[poll([^\]]*)\]([\s\S]*?)\[/poll\]\s*$',
    ).firstMatch(source);
    if (m == null) return null;

    final attrs = <String, String>{};
    for (final a in RegExp(
      r'''(\w+)=(?:"([^"]*)"|'([^']*)'|(\S+))''',
    ).allMatches(m.group(1)!)) {
      attrs[a.group(1)!.toLowerCase()] = a.group(2) ?? a.group(3) ?? a.group(4)!;
    }

    String title = '';
    final options = <String>[];
    for (final line in m.group(2)!.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('# ') && title.isEmpty) {
        title = t.substring(2).trim();
      } else if (t.startsWith('* ') || t.startsWith('- ')) {
        options.add(t.substring(2).trim());
      } else {
        // 体内出现无法归类的行(嵌套块等)→ 表单会丢内容,拒绝解析
        return null;
      }
    }

    final type = attrs['type'] ?? kPollTypeRegular;
    if (type != kPollTypeRegular &&
        type != kPollTypeMultiple &&
        type != kPollTypeNumber) {
      return null; // ranked_choice 等表单不支持,走源码编辑
    }
    return PollSpec(
      type: type,
      results: attrs['results'] ?? 'always',
      public: attrs['public'] == 'true',
      chartType: (attrs['charttype'] ?? 'bar') == 'pie' ? 'pie' : 'bar',
      title: title,
      options: options,
      min: int.tryParse(attrs['min'] ?? ''),
      max: int.tryParse(attrs['max'] ?? ''),
      step: int.tryParse(attrs['step'] ?? ''),
      close: TimeUtils.parseUtcTime(attrs['close']),
      extraAttrs: {
        for (final e in attrs.entries)
          if (!_managedKeys.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// 组装 `[poll ...]` BBCode。属性输出规则对齐官方 poll-ui-builder:
  /// min/max 仅非 regular;step 仅 number;public 恒输出;
  /// chartType 非 number 才输出;number 型不写选项行。
  String toBBCode({int existingPollCount = 0}) {
    final sb = StringBuffer('[poll');
    // 编辑态保留原 name;新建时同帖多投票 name 唯一(官方 pollN 递增)
    final name = extraAttrs['name'];
    if (name != null && name.isNotEmpty) {
      sb.write(name.contains(' ') ? ' name="$name"' : ' name=$name');
    } else if (existingPollCount > 0) {
      sb.write(' name=poll${existingPollCount + 1}');
    }
    sb.write(' type=$type results=$results');
    if (type != kPollTypeRegular) {
      if (min != null) sb.write(' min=$min');
      if (max != null) sb.write(' max=$max');
    }
    if (type == kPollTypeNumber) sb.write(' step=${step ?? 1}');
    sb.write(' public=$public');
    if (type != kPollTypeNumber) sb.write(' chartType=$chartType');
    if (close != null) {
      sb.write(' close=${close!.toUtc().toIso8601String()}');
    }
    // 未建模属性原样写回(status/groups/dynamic…);name 已单独处理
    for (final e in extraAttrs.entries) {
      if (e.key == 'name') continue;
      sb.write(
        e.value.contains(' ')
            ? ' ${e.key}="${e.value}"'
            : ' ${e.key}=${e.value}',
      );
    }
    sb.writeln(']');
    final t = title.trim();
    if (t.isNotEmpty) sb.writeln('# $t');
    if (type != kPollTypeNumber) {
      for (final opt in options) {
        final o = opt.trim();
        if (o.isNotEmpty) sb.writeln('* $o');
      }
    }
    sb.write('[/poll]');
    return sb.toString();
  }
}

Future<PollSpec?> showPollBuilderDialog(
  BuildContext context, {
  int existingPollCount = 0,
  PollSpec? initial,
}) {
  return showAppDialog<PollSpec>(
    context: context,
    builder: (_) => _PollBuilderDialog(initial: initial),
  );
}

class _PollBuilderDialog extends StatefulWidget {
  const _PollBuilderDialog({this.initial});

  final PollSpec? initial;

  @override
  State<_PollBuilderDialog> createState() => _PollBuilderDialogState();
}

class _PollBuilderDialogState extends State<_PollBuilderDialog> {
  late String _type = widget.initial?.type ?? kPollTypeRegular;
  late String _results = widget.initial?.results ?? 'always';
  late bool _public = widget.initial?.public ?? true;
  late String _chartType = widget.initial?.chartType ?? 'bar';
  late DateTime? _close = widget.initial?.close;
  // 编辑态默认展开高级区(带了非默认高级属性时用户需要看得见)
  late bool _showAdvanced = widget.initial != null &&
      (widget.initial!.results != 'always' ||
          !widget.initial!.public ||
          widget.initial!.chartType != 'bar' ||
          widget.initial!.close != null);
  String? _error;

  late final TextEditingController _title =
      TextEditingController(text: widget.initial?.title ?? '');
  late final List<TextEditingController> _options = [
    for (final o in widget.initial?.options ?? const <String>[])
      TextEditingController(text: o),
    if ((widget.initial?.options ?? const []).isEmpty) ...[
      TextEditingController(),
      TextEditingController(),
    ],
  ];
  // multiple: min/max;number: min/max/step
  late final TextEditingController _min =
      TextEditingController(text: '${widget.initial?.min ?? 1}');
  late final TextEditingController _max = TextEditingController(
    text:
        '${widget.initial?.max ?? (widget.initial?.type == kPollTypeNumber ? 10 : 2)}',
  );
  late final TextEditingController _step =
      TextEditingController(text: '${widget.initial?.step ?? 1}');

  @override
  void dispose() {
    _title.dispose();
    for (final c in _options) {
      c.dispose();
    }
    _min.dispose();
    _max.dispose();
    _step.dispose();
    super.dispose();
  }

  List<String> get _validOptions => [
        for (final c in _options)
          if (c.text.trim().isNotEmpty) c.text.trim(),
      ];

  /// 切类型时重置数字区默认值(官方 enforceMinMaxValues 同思路)。
  void _onTypeChanged(String type) {
    setState(() {
      _type = type;
      _error = null;
      if (type == kPollTypeMultiple) {
        _min.text = '1';
        _max.text = '${_validOptions.length.clamp(2, 999)}';
      } else if (type == kPollTypeNumber) {
        _min.text = '1';
        _max.text = '10';
        _step.text = '1';
      }
    });
  }

  /// 校验并组装结果;失败置 _error 返回 null(对齐官方
  /// minNumOfOptionsValidation / minMaxValueValidation)。
  PollSpec? _validate() {
    final min = int.tryParse(_min.text.trim());
    final max = int.tryParse(_max.text.trim());
    final step = int.tryParse(_step.text.trim());
    final options = _validOptions;

    if (_type != kPollTypeNumber && options.isEmpty) {
      _error = '至少需要 1 个选项';
      return null;
    }
    if (_type == kPollTypeMultiple) {
      if (min == null || max == null || min < 1 || min > max ||
          max > options.length) {
        _error = '需满足 1 ≤ 最少 ≤ 最多 ≤ 选项数(${options.length})';
        return null;
      }
    }
    if (_type == kPollTypeNumber) {
      if (min == null || max == null || step == null || min < 0 ||
          max < min) {
        _error = '需满足最小值 ≤ 最大值';
        return null;
      }
      if (step < 1) {
        _error = '步长至少为 1';
        return null;
      }
      if ((max - min + 1) / step < 2) {
        _error = '范围除以步长至少要产生 2 个选项';
        return null;
      }
    }
    return PollSpec(
      type: _type,
      results: _results,
      public: _public,
      chartType: _chartType,
      title: _title.text,
      options: options,
      min: _type == kPollTypeRegular ? null : min,
      max: _type == kPollTypeRegular ? null : max,
      step: _type == kPollTypeNumber ? step : null,
      close: _close,
      extraAttrs: widget.initial?.extraAttrs ?? const {},
    );
  }

  void _submit() {
    final spec = _validate();
    if (spec == null) {
      setState(() {});
      return;
    }
    Navigator.of(context).pop(spec);
  }

  Future<void> _pickClose() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _close ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _close != null
          ? TimeOfDay.fromDateTime(_close!)
          : const TimeOfDay(hour: 12, minute: 0),
    );
    if (!mounted) return;
    setState(() {
      _close = DateTime(date.year, date.month, date.day, time?.hour ?? 12,
          time?.minute ?? 0);
    });
  }

  String get _closeLabel {
    final c = _close;
    if (c == null) return '不自动关闭';
    return '${c.year}-${c.month.toString().padLeft(2, '0')}-'
        '${c.day.toString().padLeft(2, '0')} '
        '${c.hour.toString().padLeft(2, '0')}:'
        '${c.minute.toString().padLeft(2, '0')}';
  }

  Widget _numField(TextEditingController c, String label) {
    return Expanded(
      child: TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isNumber = _type == kPollTypeNumber;
    return AlertDialog(
      title: Text(widget.initial == null ? '创建投票' : '编辑投票'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              M3eButtonGroup<String>(
                items: const [
                  M3eButtonGroupItem(
                      value: kPollTypeRegular, label: Text('单选')),
                  M3eButtonGroupItem(
                      value: kPollTypeMultiple, label: Text('多选')),
                  M3eButtonGroupItem(
                      value: kPollTypeNumber, label: Text('评分')),
                ],
                selected: _type,
                onSelected: _onTypeChanged,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '标题(可空)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              if (!isNumber) ...[
                for (var i = 0; i < _options.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _options[i],
                            decoration: InputDecoration(
                              labelText: '选项 ${i + 1}',
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '删除选项',
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: _options.length <= 1
                              ? null
                              : () => setState(
                                  () => _options.removeAt(i).dispose()),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加选项'),
                    onPressed: () => setState(
                        () => _options.add(TextEditingController())),
                  ),
                ),
              ],
              if (_type == kPollTypeMultiple)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    _numField(_min, '至少选'),
                    const SizedBox(width: 8),
                    _numField(_max, '至多选'),
                  ]),
                ),
              if (isNumber)
                Row(children: [
                  _numField(_min, '最小值'),
                  const SizedBox(width: 8),
                  _numField(_max, '最大值'),
                  const SizedBox(width: 8),
                  _numField(_step, '步长'),
                ]),
              const SizedBox(height: 4),
              // 高级选项折叠区(仿官方 showAdvanced)
              InkWell(
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        _showAdvanced
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '高级选项',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showAdvanced) ...[
                DropdownButtonFormField<String>(
                  initialValue: _results,
                  decoration: const InputDecoration(
                    labelText: '结果可见性',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final (v, label) in kPollResults)
                      DropdownMenuItem(value: v, child: Text(label)),
                  ],
                  onChanged: (v) =>
                      setState(() => _results = v ?? 'always'),
                ),
                SwitchListTile(
                  value: _public,
                  onChanged: (v) => setState(() => _public = v),
                  title: const Text('公开投票人', style: TextStyle(fontSize: 14)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                if (!isNumber)
                  Row(
                    children: [
                      Text('图表',
                          style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant)),
                      const SizedBox(width: 10),
                      ChoiceChip(
                        label: const Text('柱状',
                            style: TextStyle(fontSize: 12)),
                        selected: _chartType == 'bar',
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) =>
                            setState(() => _chartType = 'bar'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('饼图',
                            style: TextStyle(fontSize: 12)),
                        selected: _chartType == 'pie',
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) =>
                            setState(() => _chartType = 'pie'),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.schedule_outlined, size: 16),
                      label: Text(_closeLabel),
                      onPressed: _pickClose,
                    ),
                  ),
                  if (_close != null)
                    IconButton(
                      tooltip: '清除自动关闭',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _close = null),
                    ),
                ]),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initial == null ? '插入' : '应用'),
        ),
      ],
    );
  }
}
