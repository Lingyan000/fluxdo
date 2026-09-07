import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluxdo/providers/sticker_provider.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表情包市场分页 / 搜索的并发时序回归测试。
///
/// 这里锁的两件事都只在「异步还在飞的时候用户又操作了一下」时才现形，
/// 手动点很难稳定复现，所以用可挂起的 adapter 把时序固定下来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MarketGroupsNotifier> newNotifier(_FakeMarketAdapter adapter) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = StickerMarketService(
      prefs,
      dio: Dio()..httpClientAdapter = adapter,
    );
    return MarketGroupsNotifier(service);
  }

  List<String> namesOf(MarketGroupsNotifier n) =>
      (n.state.value ?? const []).map((g) => g.name).toList();

  test('切分类时在飞的翻页结果不会混进新分类', () async {
    final adapter = _FakeMarketAdapter({
      '/assets/market/index/page-1.json': _page(['all-1', 'all-2'], 2),
      '/assets/market/index/page-2.json': _page(['all-3'], 2),
      '/assets/market/index/x-page-1.json': _page(['x-1'], 1),
    })..hold('/assets/market/index/page-2.json');

    final notifier = await newNotifier(adapter);
    await pumpEventQueue();
    expect(namesOf(notifier), ['all-1', 'all-2']);

    // page-2 起飞后立刻切到别的分类，然后才让 page-2 落地
    final pending = notifier.loadMore();
    await notifier.setTopic('x');
    adapter.release('/assets/market/index/page-2.json');
    await pending;
    await pumpEventQueue();

    expect(namesOf(notifier), ['x-1'], reason: '旧分类的页必须整包丢弃');
    expect(notifier.hasMore, isFalse, reason: '分页游标不能被旧分类的 totalPages 覆盖');
  });

  test('首屏还在加载时就输入搜索词，首页数据不会被丢弃', () async {
    final adapter = _FakeMarketAdapter({
      '/assets/market/index/page-1.json': _page(['alpha', 'beta'], 1),
    })..hold('/assets/market/index/page-1.json');

    final notifier = await newNotifier(adapter);
    // 首页仍在飞：搜索只能作废「搜索补页」，不能作废首页加载
    final searching = notifier.setQuery('alpha');
    adapter.release('/assets/market/index/page-1.json');
    await searching;
    await pumpEventQueue();

    expect(namesOf(notifier), ['alpha']);

    // 清空搜索词应回到完整浏览态，而不是空列表
    await notifier.setQuery('');
    expect(namesOf(notifier), ['alpha', 'beta']);
  });

  test('首屏加载完成后若已处于搜索态，会补齐剩余页再过滤', () async {
    final adapter = _FakeMarketAdapter({
      '/assets/market/index/page-1.json': _page(['alpha', 'beta'], 2),
      '/assets/market/index/page-2.json': _page(['alphabet'], 2),
    })..hold('/assets/market/index/page-1.json');

    final notifier = await newNotifier(adapter);
    final searching = notifier.setQuery('alpha');
    adapter.release('/assets/market/index/page-1.json');
    await searching;
    await pumpEventQueue();

    expect(namesOf(notifier), [
      'alpha',
      'alphabet',
    ], reason: '第 2 页的命中不能因为搜索发生在首屏之前就漏掉');
  });
}

Map<String, dynamic> _page(List<String> names, int totalPages) => {
  'totalPages': totalPages,
  'groups': [
    for (final name in names)
      {
        'id': 'group-$name',
        'name': name,
        'icon': '',
        'order': 0,
        'emojiCount': 1,
        'isArchived': false,
      },
  ],
};

/// 按路径返回固定 body 的假适配器，可对指定路径「扣住」响应以固定时序。
class _FakeMarketAdapter implements HttpClientAdapter {
  _FakeMarketAdapter(this.bodies);

  final Map<String, Map<String, dynamic>> bodies;
  final Map<String, Completer<void>> _gates = {};

  void hold(String path) => _gates[path] = Completer<void>();

  void release(String path) => _gates.remove(path)?.complete();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    await _gates[path]?.future;
    final body = bodies[path];
    if (body == null) {
      throw StateError('测试未配置的路径：$path');
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
