import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../cookie_service.dart';

/// Events tab: 实时订阅主 app 推送的 SweepEvent。
///
/// 保留最近 200 条; 支持按类型过滤。
class EventsTab extends StatefulWidget {
  const EventsTab({super.key});

  @override
  State<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab> {
  static const _maxRecords = 200;

  final Queue<_EventRecord> _events = Queue();
  StreamSubscription<Map<String, dynamic>>? _sub;
  String? _filterType; // null = 全部

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  Future<void> _subscribe() async {
    await CookieService.instance.ensureStreamListening();
    _sub = CookieService.instance.sweepEvents().listen((payload) {
      final record = _EventRecord.fromPayload(payload);
      if (!mounted) return;
      setState(() {
        _events.addFirst(record);
        while (_events.length > _maxRecords) {
          _events.removeLast();
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<_EventRecord> get _filtered {
    if (_filterType == null) return _events.toList();
    return _events.where((e) => e.type == _filterType).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildFilterBar(),
        Expanded(
          child: _events.isEmpty
              ? const Center(child: Text('暂无事件 (触发任意 cookie 操作后会出现)'))
              : ListView.builder(
                  itemCount: _filtered.length,
                  itemBuilder: (context, i) => _EventTile(record: _filtered[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildFilterBar() {
    final types = ['SweepInvoked', 'SweepCompleted', 'SweepCancelled'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Text('过滤: '),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('全部'),
            selected: _filterType == null,
            onSelected: (_) => setState(() => _filterType = null),
          ),
          const SizedBox(width: 4),
          ...types.map(
            (t) => Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ChoiceChip(
                label: Text(t.replaceFirst('Sweep', '')),
                selected: _filterType == t,
                onSelected: (_) => setState(() => _filterType = t),
              ),
            ),
          ),
          const Spacer(),
          Text('共 ${_events.length} 条 (最多 $_maxRecords)'),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清空',
            onPressed: () => setState(_events.clear),
          ),
        ],
      ),
    );
  }
}

class _EventRecord {
  _EventRecord({
    required this.timestamp,
    required this.type,
    required this.payload,
  });

  factory _EventRecord.fromPayload(Map<String, dynamic> payload) {
    return _EventRecord(
      timestamp: payload['timestamp']?.toString() ?? '',
      type: payload['type']?.toString() ?? 'Unknown',
      payload: payload,
    );
  }

  final String timestamp;
  final String type;
  final Map<String, dynamic> payload;
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.record});
  final _EventRecord record;

  Color _typeColor(BuildContext context) {
    switch (record.type) {
      case 'SweepInvoked':
        return Colors.blue;
      case 'SweepCompleted':
        final status = (record.payload['result']
                as Map<String, dynamic>?)?['status'];
        if (status == 'failed') return Colors.red;
        if (status == 'nuclearReset') return Colors.deepOrange;
        if (status == 'noop') return Colors.grey;
        return Colors.green;
      case 'SweepCancelled':
        return Colors.orange;
      default:
        return Theme.of(context).colorScheme.onSurface;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _typeColor(context);
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.2),
        radius: 14,
        child: Icon(Icons.event, size: 14, color: color),
      ),
      title: Text(
        record.type,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(_buildSubtitle()),
      trailing: Text(
        _formatTime(record.timestamp),
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () => _showDetails(context),
    );
  }

  String _buildSubtitle() {
    if (record.type == 'SweepCompleted') {
      final result = record.payload['result'] as Map<String, dynamic>?;
      if (result != null) {
        return '${result['name']}: ${result['status']} '
            '(${result['variantsBefore']} → ${result['variantsAfter']}, '
            '${result['elapsedMs']}ms)';
      }
    }
    final name = record.payload['name'];
    final url = record.payload['url'];
    return [if (name != null) name, if (url != null) url].join(' @ ');
  }

  String _formatTime(String iso) {
    if (iso.length < 19) return iso;
    return iso.substring(11, 19);
  }

  void _showDetails(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(record.type),
        content: SingleChildScrollView(
          child: SelectableText(
            encoder.convert(record.payload),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
