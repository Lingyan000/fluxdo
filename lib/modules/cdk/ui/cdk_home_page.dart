import 'dart:async';
import 'dart:math' as math;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../providers/cdk_providers.dart';
import '../../../utils/link_launcher.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../../../widgets/common/paged_list_footer.dart';
import '../models/cdk_models.dart';
import '../services/cdk_client.dart';
import 'cdk_project_page.dart';
import 'cdk_widgets.dart';

class CdkHomePage extends StatelessWidget {
  const CdkHomePage({super.key});
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(InteractionPageRoute<void>(builder: (_) => const CdkHomePage()));
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('LINUX DO CDK'),
      actions: [
        IconButton(
          tooltip: context.l10n.cdk_openWebsite,
          onPressed: () => launchExternalLink(
            context,
            '${CdkClient.origin}/dashboard',
            mode: LinkOpenMode.inApp,
          ),
          icon: const Icon(Symbols.open_in_browser_rounded),
        ),
      ],
    ),
    body: CdkSessionGate(builder: (client) => CdkHomeContent(client: client)),
  );
}

class CdkHomeContent extends ConsumerStatefulWidget {
  const CdkHomeContent({super.key, required this.client});
  final CdkClient client;
  @override
  ConsumerState<CdkHomeContent> createState() => _CdkHomeContentState();
}

class _CdkHomeContentState extends ConsumerState<CdkHomeContent> {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            isScrollable:
                MediaQuery.textScalerOf(context).scale(14) > 17 ||
                MediaQuery.sizeOf(context).width < 360,
            tabs: [
              Tab(text: l.cdk_explore),
              Tab(text: l.cdk_myReceipts),
              Tab(text: l.cdk_overview),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _Explore(client: widget.client),
                _Receipts(client: widget.client),
                _Overview(client: widget.client),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Explore extends StatefulWidget {
  const _Explore({required this.client});
  final CdkClient client;
  @override
  State<_Explore> createState() => _ExploreState();
}

class _ExploreState extends State<_Explore> with AutomaticKeepAliveClientMixin {
  List<String> _tags = [];
  String? _tag;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    widget.client
        .tags()
        .then((tags) {
          if (mounted) setState(() => _tags = tags);
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        if (_tags.isNotEmpty)
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final tag in <String?>[null, ..._tags])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(tag ?? context.l10n.common_all),
                      selected: _tag == tag,
                      onSelected: (_) => setState(() => _tag = tag),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _Paged<CdkProject>(
            key: ValueKey(_tag),
            load: (page) => widget.client.projects(page: page, tag: _tag),
            item: (p) => ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              onTap: () => CdkProjectPage.open(context, p.id),
              title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p.description.isNotEmpty)
                      Text(
                        p.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        Text(
                          p.paid ? '${p.price} LDC' : context.l10n.cdk_free,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                        Text('Lv.${p.trustLevel}'),
                        Text(context.l10n.cdk_projectTotal(p.total)),
                      ],
                    ),
                    if (p.tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          p.tags.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Receipts extends StatefulWidget {
  const _Receipts({required this.client});
  final CdkClient client;
  @override
  State<_Receipts> createState() => _ReceiptsState();
}

class _ReceiptsState extends State<_Receipts>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  @override
  bool get wantKeepAlive => true;
  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: InputFieldShell(
            child: TextField(
              controller: _search,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                hintText: context.l10n.cdk_searchReceipts,
                prefixIcon: const Icon(Symbols.search_rounded),
                isDense: true,
              ),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), () {
                  if (mounted) setState(() => _query = value.trim());
                });
              },
            ),
          ),
        ),
        Expanded(
          child: _Paged<CdkReceipt>(
            key: ValueKey(_query),
            load: (page) => widget.client.receipts(page: page, search: _query),
            item: (receipt) => ListTile(
              title: Text(
                receipt.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '@${receipt.creator}\n${TimeUtils.formatDetailTime(receipt.receivedAt)}',
              ),
              isThreeLine: true,
              onTap: () => AppBottomSheet.show<void>(
                context: context,
                title: receipt.name,
                builder: (_) => CdkSessionContent(
                  client: widget.client,
                  builder: (_) => SingleChildScrollView(
                    child: CdkSecretContent(content: receipt.content),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Paged<T> extends StatefulWidget {
  const _Paged({super.key, required this.load, required this.item});
  final Future<CdkPage<T>> Function(int page) load;
  final Widget Function(T) item;
  @override
  State<_Paged<T>> createState() => _PagedState<T>();
}

class _PagedState<T> extends State<_Paged<T>> {
  final _scroll = ScrollController();
  List<T> _items = [];
  bool _loading = false, _more = true;
  int _page = 0, _generation = 0;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadMore);
    unawaited(_load(reset: true));
  }

  void _loadMore() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 300 &&
        !_loading &&
        _more &&
        _error == null) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || !mounted) return;
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = reset ? 1 : _page + 1;
      final result = await widget.load(next);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items = [if (!reset) ..._items, ...result.items];
        _page = next;
        _more = result.items.isNotEmpty && _items.length < result.total;
      });
    } catch (error) {
      if (mounted && gen == _generation) setState(() => _error = error);
    } finally {
      if (mounted && gen == _generation) {
        setState(() => _loading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadMore();
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty && _loading) {
      return const Center(child: LoadingSpinner());
    }
    if (_items.isEmpty && _error != null) {
      return CdkError(error: _error, retry: () => _load(reset: true));
    }
    return M3eRefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: _items.length + 1,
        itemBuilder: (context, index) {
          if (index == _items.length) {
            if (_items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 72),
                child: AppEmptyState(
                  icon: const Icon(Symbols.inbox_rounded),
                  title: context.l10n.cdk_empty,
                ),
              );
            }
            return PagedListFooter(
              hasMore: _more,
              isLoadingMore: _loading,
              isLoadMoreFailed: _error != null,
              onRetry: () => _load(),
            );
          }
          return SegmentedCardItem(
            index: index,
            count: _items.length,
            child: widget.item(_items[index]),
          );
        },
      ),
    );
  }
}

class _Overview extends ConsumerStatefulWidget {
  const _Overview({required this.client});
  final CdkClient client;
  @override
  ConsumerState<_Overview> createState() => _OverviewState();
}

class _OverviewState extends ConsumerState<_Overview>
    with AutomaticKeepAliveClientMixin {
  late Future<CdkDashboard> _stats;
  late Future<List<Map<String, dynamic>>> _history;
  int _days = 7;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _stats = widget.client.dashboard(days: _days);
    _history = widget.client.history(days: _days);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = context.l10n;
    final account = ref.watch(cdkUserInfoProvider).value;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (account != null) ...[
          CdkMetrics(
            values: [
              (l.cdk_balance, '${account.score}'),
              (l.cdk_requiredTrust, 'Lv.${account.trustLevel}'),
            ],
          ),
          Text(l.cdk_scoreHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),
        ],
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                children: [
                  for (final days in [7, 15, 30])
                    ChoiceChip(
                      label: Text(l.cdk_days(days)),
                      selected: _days == days,
                      onSelected: (_) => setState(() {
                        _days = days;
                        _reload();
                      }),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: l.common_refresh,
              onPressed: () => setState(_reload),
              icon: const Icon(Symbols.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          l.cdk_personalTrend,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        FutureBuilder(
          future: _history,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: LoadingSpinner());
            }
            if (snapshot.hasError) {
              return CdkError(
                error: snapshot.error,
                retry: () => setState(_reload),
              );
            }
            return _Trend(
              points: snapshot.data!,
              dateKey: 'date',
              countKey: 'count',
            );
          },
        ),
        const SizedBox(height: 24),
        Text(
          l.cdk_platformStats,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        FutureBuilder(
          future: _stats,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: LoadingSpinner());
            }
            if (snapshot.hasError) {
              return CdkError(
                error: snapshot.error,
                retry: () => setState(_reload),
              );
            }
            final stats = snapshot.data!;
            if (stats.summary.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l.cdk_statsEmpty),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CdkMetrics(
                  values: [
                    (l.cdk_totalUsers, '${stats.summary['totalUsers'] ?? '—'}'),
                    (
                      l.cdk_totalProjects,
                      '${stats.summary['totalProjects'] ?? '—'}',
                    ),
                    (
                      l.cdk_totalReceived,
                      '${stats.summary['totalReceived'] ?? '—'}',
                    ),
                    (
                      l.cdk_recentReceived,
                      '${stats.summary['recentReceived'] ?? '—'}',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _Trend(
                  points: stats.activity,
                  dateKey: 'date',
                  countKey: 'value',
                ),
                if (stats.tags.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    l.cdk_popularTags,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final tag in stats.tags)
                        Chip(label: Text('${tag['name']} · ${tag['value']}')),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend({
    required this.points,
    required this.dateKey,
    required this.countKey,
  });
  final List<Map<String, dynamic>> points;
  final String dateKey, countKey;
  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return Text(context.l10n.cdk_statsEmpty);
    final maximum = points.fold<double>(
      1,
      (max, row) => math.max(max, (row[countKey] as num? ?? 0).toDouble()),
    );
    return SizedBox(
      height: 125,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: points.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final row = points[index];
          final count = (row[countKey] as num? ?? 0).toDouble();
          final date = '${row[dateKey]}';
          return Semantics(
            label: '$date: $count',
            child: SizedBox(
              width: 48,
              child: Column(
                children: [
                  Text(
                    '${count.toInt()}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: 18,
                        height: math.max(2, 68 * count / maximum),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: context.shapes.borderRadius(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    date.length >= 10 ? date.substring(5, 10) : date,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
