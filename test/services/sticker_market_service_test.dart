import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<StickerMarketService> newService(_RecordingAdapter adapter) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return StickerMarketService(prefs, dio: Dio()..httpClientAdapter = adapter);
  }

  group('分组详情文件名', () {
    test('id 已带 group- 前缀时不再重复拼接', () async {
      final adapter = _RecordingAdapter();
      final service = await newService(adapter);

      await service.getGroupDetail('group-123');

      expect(adapter.paths, ['/assets/market/group-123.json']);
    });

    test('兼容仍使用裸 id 的旧数据', () async {
      final adapter = _RecordingAdapter();
      final service = await newService(adapter);

      await service.getGroupDetail('123');

      expect(adapter.paths, ['/assets/market/group-123.json']);
    });
  });

  group('分类分页文件名', () {
    // 服务端对不存在的资源返回 200 + SPA 首页 HTML(不是 404),所以这几条
    // 路径一旦拼错不会响,只会拿到空列表或类型错误 —— 必须锁死。
    test('全部分类走 page-N.json,不能带 all- 前缀', () async {
      final adapter = _RecordingAdapter();
      final service = await newService(adapter);

      await service.getGroupsPageWithMeta(1);
      await service.getGroupsPageWithMeta(2, topic: 'all');

      expect(adapter.paths, [
        '/assets/market/index/page-1.json',
        '/assets/market/index/page-2.json',
      ]);
    });

    test('具体分类走 {topic}-page-N.json', () async {
      final adapter = _RecordingAdapter();
      final service = await newService(adapter);

      await service.getGroupsPageWithMeta(2, topic: 'x');
      await service.getGroupsPage(1, topic: 'linux.do');

      expect(adapter.paths, [
        '/assets/market/index/x-page-2.json',
        '/assets/market/index/linux.do-page-1.json',
      ]);
    });

    test('totalPages 取页文件自带的元信息(各分类互不相同)', () async {
      final adapter = _RecordingAdapter(totalPages: 6);
      final service = await newService(adapter);

      final (groups, totalPages) = await service.getGroupsPageWithMeta(1);

      expect(totalPages, 6);
      expect(groups, isEmpty);
    });

    test('缓存键按 topic 隔离,不同分类同页码不会互相命中', () async {
      final adapter = _RecordingAdapter();
      final service = await newService(adapter);

      await service.getGroupsPage(1);
      await service.getGroupsPage(1, topic: 'x');
      // 同一 (topic, page) 第二次应命中缓存,不再发请求
      await service.getGroupsPage(1, topic: 'x');

      expect(adapter.paths, [
        '/assets/market/index/page-1.json',
        '/assets/market/index/x-page-1.json',
      ]);
    });
  });

  group('分类列表', () {
    test('topics 走独立的 topics.json', () async {
      final adapter = _RecordingAdapter();
      final service = await newService(adapter);

      await service.getTopics();

      expect(adapter.paths, ['/assets/market/index/topics.json']);
    });
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.totalPages = 1});

  final int totalPages;
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    // 同时满足分组详情 / 分页 / 分类三种解析,省掉多套 fixture
    return ResponseBody.fromString(
      jsonEncode({
        'id': 'group-123',
        'name': 'test',
        'icon': '🙂',
        'emojis': <dynamic>[],
        'groups': <dynamic>[],
        'topics': <dynamic>[],
        'totalPages': totalPages,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
