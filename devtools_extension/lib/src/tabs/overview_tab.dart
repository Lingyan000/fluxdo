import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../cookie_service.dart';

/// Overview tab: jar + WV cookie 双视图 + Priming 状态 + critical 变体数。
///
/// 默认 5 秒自动刷新; 支持手动刷新和 raw JSON 模式。
class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key});

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  Map<String, dynamic>? _data;
  bool _loading = false;
  bool _rawMode = false;
  String? _error;
  Timer? _autoRefresh;

  static const _refreshInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _fetch();
    _autoRefresh = Timer.periodic(_refreshInterval, (_) => _fetch());
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await CookieService.instance.dump();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'toggle-raw',
            onPressed: () => setState(() => _rawMode = !_rawMode),
            tooltip: _rawMode ? '切换到结构视图' : '切换到 raw JSON',
            child: Icon(_rawMode ? Icons.view_list : Icons.code),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.small(
            heroTag: 'refresh',
            onPressed: _loading ? null : _fetch,
            tooltip: '刷新',
            child: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Error: $_error',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
    final data = _data;
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rawMode) {
      return _buildRawJsonView(data);
    }
    return _buildStructuredView(data);
  }

  Widget _buildRawJsonView(Map<String, dynamic> data) {
    const encoder = JsonEncoder.withIndent('  ');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        encoder.convert(data),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }

  Widget _buildStructuredView(Map<String, dynamic> data) {
    final priming = data['priming'] as Map<String, dynamic>? ?? {};
    final jar = data['jar'] as Map<String, dynamic>? ?? {};
    final wv = data['webview'] as Map<String, dynamic>? ?? {};
    final variantsCount =
        (wv['criticalVariantsCount'] as Map?)?.cast<String, dynamic>() ?? {};

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _StatusCard(
          url: data['url']?.toString() ?? '',
          timestamp: data['timestamp']?.toString() ?? '',
          isPrimed: priming['isPrimed'] as bool? ?? false,
          variantsCount: variantsCount,
        ),
        const SizedBox(height: 12),
        _CookieListCard(
          title: 'jar (${(jar['cookies'] as List?)?.length ?? 0})',
          initialized: jar['initialized'] as bool? ?? false,
          cookies: (jar['cookies'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        ),
        const SizedBox(height: 12),
        _CookieListCard(
          title: 'WebView (${(wv['cookies'] as List?)?.length ?? 0})',
          initialized: true,
          cookies: (wv['cookies'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.url,
    required this.timestamp,
    required this.isPrimed,
    required this.variantsCount,
  });

  final String url;
  final String timestamp;
  final bool isPrimed;
  final Map<String, dynamic> variantsCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasVariantWarning =
        variantsCount.values.any((v) => v is int && v > 1);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cookie_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    url,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              timestamp,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 16),
            Row(
              children: [
                Icon(
                  isPrimed ? Icons.check_circle : Icons.pending,
                  size: 16,
                  color: isPrimed ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text('Priming: ${isPrimed ? "ready" : "pending"}'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  hasVariantWarning ? Icons.warning : Icons.check_circle,
                  size: 16,
                  color: hasVariantWarning ? Colors.red : Colors.green,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: variantsCount.entries.map((e) {
                      final count = e.value is int ? e.value as int : 0;
                      final danger = count > 1;
                      return Chip(
                        label: Text('${e.key}: $count'),
                        backgroundColor: danger
                            ? Colors.red.withValues(alpha: 0.2)
                            : null,
                        visualDensity: VisualDensity.compact,
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CookieListCard extends StatelessWidget {
  const _CookieListCard({
    required this.title,
    required this.initialized,
    required this.cookies,
  });

  final String title;
  final bool initialized;
  final List<Map<String, dynamic>> cookies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
                if (!initialized)
                  const Chip(
                    label: Text('uninitialized'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (cookies.isEmpty)
              Text(
                '(empty)',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              ...cookies.map(_buildCookieRow),
          ],
        ),
      ),
    );
  }

  Widget _buildCookieRow(Map<String, dynamic> c) {
    final isCritical = c['isCritical'] == true;
    final name = c['name']?.toString() ?? '?';
    final valueLength = c['valueLength'] ?? 0;
    final domain = c['domain']?.toString() ?? '(host-only)';
    final path = c['path']?.toString() ?? '/';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            isCritical ? Icons.star : Icons.cookie_outlined,
            size: 14,
            color: isCritical ? Colors.orange : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$name (len=$valueLength)',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: isCritical ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            '$domain $path',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
