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
import 'cdk_project_widgets.dart';
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: DefaultTabController(
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
        ),
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
  late final _tags = widget.client.tags();
  String? _tag;
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        FutureBuilder<List<String>>(
          future: _tags,
          builder: (context, snapshot) => _ProjectTagBar(
            tags: snapshot.connectionState == ConnectionState.done
                ? snapshot.data ?? const []
                : null,
            selected: _tag,
            onSelected: (tag) {
              if (tag != _tag) setState(() => _tag = tag);
            },
          ),
        ),
        Expanded(
          child: _Paged<CdkProject>(
            key: ValueKey(_tag),
            load: (page) => widget.client.projects(page: page, tag: _tag),
            item: (p) => CdkProjectTile(
              project: p,
              onTap: () => CdkProjectPage.open(context, p.id),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProjectTagBar extends StatelessWidget {
  const _ProjectTagBar({
    required this.tags,
    required this.selected,
    required this.onSelected,
  });

  final List<String>? tags;
  final String? selected;
  final ValueChanged<String?> onSelected;
  static const _duration = Duration(milliseconds: 220);
  static final _fade = M3eMotion.defaultEffects.curveFor(_duration);

  @override
  Widget build(BuildContext context) {
    final options = tags;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    final empty = options != null && options.isEmpty;
    if (empty && reduceMotion) return const SizedBox.shrink();

    final trailing = options == null || options.isEmpty
        ? const ExcludeSemantics(
            child: IgnorePointer(
              child: Row(
                spacing: 8,
                children: [_TagPlaceholder(), _TagPlaceholder()],
              ),
            ),
          )
        : Row(
            spacing: 8,
            children: [
              for (final tag in options)
                ChoiceChip(
                  label: Text(tag),
                  selected: selected == tag,
                  onSelected: (_) => onSelected(tag),
                ),
            ],
          );
    final bar = SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          spacing: 8,
          children: [
            ChoiceChip(
              label: Text(context.l10n.common_all),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
            if (reduceMotion)
              trailing
            else
              AnimatedSwitcher(
                duration: _duration,
                switchInCurve: _fade,
                layoutBuilder: (current, previous) => Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [...previous, ?current],
                ),
                child: trailing,
              ),
          ],
        ),
      ),
    );
    if (reduceMotion) return bar;
    return AnimatedCrossFade(
      duration: _duration,
      sizeCurve: Curves.easeInOutCubic,
      firstChild: bar,
      secondChild: const SizedBox(width: double.infinity),
      crossFadeState: empty
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
    );
  }
}

class _TagPlaceholder extends StatelessWidget {
  const _TagPlaceholder();

  @override
  Widget build(BuildContext context) {
    // 保留本地化标签排版，只隐藏文字，由 ChoiceChip 绘制与真实标签等高的轮廓。
    return ChoiceChip(
      label: Opacity(opacity: 0, child: Text(context.l10n.common_all)),
      selected: false,
      disabledColor: Theme.of(context).colorScheme.surfaceContainerHighest
          .withAlpha(100),
      // 保留描边占用的空间，否则上下会各缩进一个像素。
      side: const BorderSide(color: Colors.transparent),
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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              leading: Icon(
                Symbols.key_rounded,
                color: context.emphasis.accent,
              ),
              title: Text(
                receipt.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
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
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SegmentedCardItem(
              index: 0,
              count: 1,
              child: widget.item(_items[index]),
            ),
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
          CdkAccountCard(account: account),
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
        CdkSectionTitle(l.cdk_personalTrend),
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
        CdkSectionTitle(l.cdk_platformStats),
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
                  CdkSectionTitle(l.cdk_popularTags),
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
      height: 100 + MediaQuery.textScalerOf(context).scale(32),
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
