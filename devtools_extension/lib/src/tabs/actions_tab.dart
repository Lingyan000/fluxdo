import 'dart:convert';

import 'package:flutter/material.dart';

import '../cookie_service.dart';

/// Actions tab: 手动触发 sweep / Nuclear Reset / Invalidate Priming。
class ActionsTab extends StatefulWidget {
  const ActionsTab({super.key});

  @override
  State<ActionsTab> createState() => _ActionsTabState();
}

class _ActionsTabState extends State<ActionsTab> {
  final _urlController =
      TextEditingController(text: 'https://linux.do');
  String _selectedName = '_t';
  String _selectedIntent = 'ensureUnique';
  String? _lastResult;
  bool _busy = false;
  List<String> _criticalNames = ['_t', '_forum_session', 'cf_clearance'];

  @override
  void initState() {
    super.initState();
    _loadCriticalNames();
  }

  Future<void> _loadCriticalNames() async {
    final names = await CookieService.instance.criticalNames();
    if (!mounted || names == null) return;
    setState(() {
      _criticalNames = names;
      if (!names.contains(_selectedName) && names.isNotEmpty) {
        _selectedName = names.first;
      }
    });
  }

  Future<void> _run(Future<Map<String, dynamic>?> Function() action) async {
    setState(() {
      _busy = true;
      _lastResult = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _lastResult = const JsonEncoder.withIndent('  ').convert(result ?? {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastResult = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: 'URL',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sweep', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedName,
                        decoration: const InputDecoration(
                          labelText: 'Cookie name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: _criticalNames
                            .map(
                              (n) => DropdownMenuItem(value: n, child: Text(n)),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedName = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _selectedIntent,
                        decoration: const InputDecoration(
                          labelText: 'Intent',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'ensureUnique',
                            child: Text('ensureUnique'),
                          ),
                          DropdownMenuItem(
                            value: 'delete',
                            child: Text('delete'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedIntent = v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.cleaning_services),
                  label: const Text('Run sweep'),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => CookieService.instance.sweep(
                            url: _urlController.text,
                            name: _selectedName,
                            intent: _selectedIntent,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nuclear Reset',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '清空 WV 中所有 critical cookies + 从 jar 重灌',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Nuclear reset'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.orange.withValues(alpha: 0.2),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => CookieService.instance.nuclearReset(
                            url: _urlController.text,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Invalidate Priming',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '强制 WebViewCookiePriming.isPrimed=false,下次 WV 调用会重新 prime',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Invalidate'),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => CookieService.instance.invalidatePriming(),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_busy)
          const Center(child: CircularProgressIndicator())
        else if (_lastResult != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Last result',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _lastResult!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
