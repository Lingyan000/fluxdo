import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_list_events.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/filter_provider.dart';
import 'package:fluxdo/providers/topic_list/sort_provider.dart';
import 'package:fluxdo/providers/topic_list/tab_state_provider.dart';
import 'package:fluxdo/providers/topic_list/topic_list_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/topic_list_updates.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Tracking extends TopicTrackingStateNotifier {
  @override
  Map<int, TrackedTopicState> build() => {};
}

Topic _topic(int id) => Topic(
  id: id,
  title: 'topic $id',
  slug: 'topic-$id',
  postsCount: 1,
  replyCount: 0,
  views: 0,
  likeCount: 0,
  categoryId: '2',
);

class _Service extends Fake implements DiscourseService {
  Completer<TopicListResponse>? incoming;
  Map<String, Object?>? lastRequest;

  @override
  Future<TopicListResponse> getFilteredTopics({
    required String filter,
    int? categoryId,
    String? categorySlug,
    String? parentCategorySlug,
    List<String>? tags,
    String? period,
    int page = 0,
    String? order,
    bool? ascending,
    String? subset,
    List<int>? topicIds,
  }) async {
    lastRequest = {
      'filter': filter,
      'categoryId': categoryId,
      'tags': tags,
      'order': order,
      'ascending': ascending,
      'subset': subset,
      'topicIds': topicIds,
    };
    if (topicIds != null) return incoming!.future;
    return TopicListResponse(topics: [_topic(filter == 'latest' ? 20 : 10)]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('按筛选隔离横幅', () {
    final cases = <(TopicListFilter, bool, NewSubset, Set<String>)>[
      (TopicListFilter.latest, false, NewSubset.all, {'new_topic', 'latest'}),
      (TopicListFilter.newTopics, false, NewSubset.all, {'new_topic'}),
      (TopicListFilter.newTopics, true, NewSubset.all, {'new_topic', 'unread'}),
      (TopicListFilter.newTopics, true, NewSubset.topics, {'new_topic'}),
      (TopicListFilter.newTopics, true, NewSubset.replies, {'unread'}),
      (TopicListFilter.unread, false, NewSubset.all, {'unread'}),
      (TopicListFilter.unseen, false, NewSubset.all, {'new_topic', 'unread'}),
      (TopicListFilter.top, true, NewSubset.all, {}),
      (TopicListFilter.hot, true, NewSubset.all, {}),
    ];
    for (final (filter, merged, subset, expected) in cases) {
      test('$filter merged=$merged subset=$subset', () {
        final queue = TopicListUpdates()
          ..configure(
            TopicListUpdateQuery(
              filter: filter,
              newNewView: merged,
              subset: subset,
            ),
          );
        final accepted = <String>{};
        for (final type in ['latest', 'new_topic', 'unread', 'read']) {
          if (queue.add(
            TopicListEvent(topicId: accepted.length + 1, type: type),
          )) {
            accepted.add(type);
          }
        }
        expect(accepted, expected);
        expect(queue.snapshot({}).length, expected.length);
      });
    }

    test('父分类包括子分类，标签按 ID 匹配且支持空列表的标签元数据', () {
      final response = TopicListResponse.fromJson({
        'topic_list': {
          'topics': [],
          'tags': [
            {'id': 42, 'name': 'dart', 'slug': 'dart-slug'},
          ],
        },
      });
      final queue = TopicListUpdates()
        ..configure(
          TopicListUpdateQuery(
            filter: TopicListFilter.newTopics,
            categoryId: 2,
            tags: ['dart'],
          ),
        )
        ..rememberTags(response.tags);
      queue.add(
        const TopicListEvent(
          topicId: 1,
          type: 'new_topic',
          categoryId: 3,
          tags: [
            {'id': 42},
          ],
        ),
      );
      queue.add(
        const TopicListEvent(
          topicId: 2,
          type: 'new_topic',
          categoryId: 2,
          tags: [
            {'id': 99},
          ],
        ),
      );
      queue.add(
        const TopicListEvent(
          topicId: 3,
          type: 'new_topic',
          categoryId: 4,
          tags: [
            {'id': 42},
          ],
        ),
      );
      expect(queue.snapshot({3: 2, 4: null}).keys, [1]);
    });

    test('多标签必须全部匹配，名称与 slug 都可解析', () {
      final queue = TopicListUpdates()
        ..configure(
          TopicListUpdateQuery(
            filter: TopicListFilter.latest,
            tags: ['dart', 'flutter'],
          ),
        )
        ..rememberTags([const Tag(id: 42, name: 'Dart语言', slug: 'dart')]);
      queue.add(
        const TopicListEvent(
          topicId: 1,
          type: 'latest',
          tags: [
            {'id': 42},
            'flutter',
          ],
        ),
      );
      queue.add(
        const TopicListEvent(topicId: 2, type: 'latest', tags: ['dart']),
      );
      expect(queue.snapshot({}).keys, [1]);
    });

    test('用户视图设置迟到时不作废正在加载的列表', () {
      final queue = TopicListUpdates()
        ..configure(TopicListUpdateQuery(filter: TopicListFilter.newTopics));
      final generation = queue.generation;
      queue.configure(
        TopicListUpdateQuery(
          filter: TopicListFilter.newTopics,
          newNewView: true,
        ),
      );
      expect(queue.generation, generation);
      queue.add(const TopicListEvent(topicId: 1, type: 'unread'));
      expect(queue.snapshot({}).keys, [1]);
    });

    test('分类多标签与接口一致，匹配任一标签即可提示', () {
      final queue = TopicListUpdates()
        ..configure(
          TopicListUpdateQuery(
            filter: TopicListFilter.latest,
            categoryId: 2,
            tags: ['dart', 'flutter'],
          ),
        );
      queue.add(
        const TopicListEvent(
          topicId: 1,
          type: 'latest',
          categoryId: 2,
          tags: ['dart'],
        ),
      );
      queue.add(
        const TopicListEvent(
          topicId: 2,
          type: 'latest',
          categoryId: 2,
          tags: ['ruby'],
        ),
      );
      expect(queue.snapshot({}).keys, [1]);
    });

    test('消费快照保留请求期间同话题的新消息，其他列表不受影响', () {
      final a = TopicListUpdates()
        ..configure(TopicListUpdateQuery(filter: TopicListFilter.latest));
      final b = TopicListUpdates()
        ..configure(TopicListUpdateQuery(filter: TopicListFilter.latest));
      const event = TopicListEvent(topicId: 1, type: 'latest');
      a.add(event);
      b.add(event);
      final snapshot = a.snapshot({});
      a.add(event);
      a.acknowledge(snapshot);
      expect(a.snapshot({}).keys, [1]);
      a.acknowledge(a.snapshot({}));
      expect(a.snapshot({}), isEmpty);
      expect(b.snapshot({}).keys, [1]);
    });

    test('切换筛选使旧请求失效，但相同筛选 rebuild 保留队列', () {
      final queue = TopicListUpdates()
        ..configure(TopicListUpdateQuery(filter: TopicListFilter.latest));
      queue.add(const TopicListEvent(topicId: 1, type: 'latest'));
      final generation = queue.generation;
      queue.configure(TopicListUpdateQuery(filter: TopicListFilter.latest));
      expect(queue.snapshot({}).keys, [1]);
      expect(queue.generation, generation);
      queue.configure(TopicListUpdateQuery(filter: TopicListFilter.newTopics));
      expect(queue.snapshot({}), isEmpty);
      expect(queue.generation, greaterThan(generation));
    });
  });

  group('统一消息入口', () {
    late ProviderContainer container;
    late List<TopicListEvent> events;
    setUp(() {
      PreloadedDataService().debugSeed(currentUser: {}, siteSettings: {});
      container = ProviderContainer(
        overrides: [
          topicTrackingStateProvider.overrideWith(_Tracking.new),
          categoryMapProvider.overrideWith(
            (ref) => const AsyncData(<int, Category>{}),
          ),
        ],
      );
      events = [];
      container.listen(topicListEventsProvider, (_, event) {
        if (event != null) events.add(event);
      });
    });
    tearDown(() {
      container.dispose();
      PreloadedDataService().debugSeed(currentUser: null, siteSettings: null);
    });
    void send(String type, {Map<String, dynamic> payload = const {}}) {
      container
          .read(topicTrackingStateProvider.notifier)
          .processChannelPayload(
            MessageBusMessage(
              channel: '/unread',
              messageId: 1,
              data: {'message_type': type, 'topic_id': 1, 'payload': payload},
            ),
          );
    }

    test('unread 按更新前的已读状态判断，连续未读推送不重复加入', () {
      send('unread', payload: {'highest_post_number': 3, 'category_id': 2});
      send('unread', payload: {'highest_post_number': 4, 'category_id': 2});
      expect(events.length, 1);
      send(
        'read',
        payload: {'last_read_post_number': 4, 'highest_post_number': 4},
      );
      send('unread', payload: {'highest_post_number': 5});
      expect(events.length, 2);
      expect(events.last.categoryId, 2);
    });
    test('话题静音和全局默认静音生效，取消静音覆盖分类静音', () {
      send('muted');
      send('latest', payload: {'category_id': 2});
      expect(events, isEmpty);
      PreloadedDataService().debugSeed(
        currentUser: {
          'muted_category_ids': [2],
        },
        siteSettings: {'mute_all_categories_by_default': true},
      );
      send('unmuted');
      send('latest', payload: {'category_id': 2});
      expect(events.length, 1);
    });
    test('静音标签同时抑制追踪与横幅', () {
      PreloadedDataService().debugSeed(
        currentUser: {
          'muted_tags': [
            {'id': 42},
          ],
        },
        siteSettings: {'remove_muted_tags_from_latest': 'always'},
      );
      send(
        'new_topic',
        payload: {
          'tags': [
            {'id': 42},
          ],
        },
      );
      expect(events, isEmpty);
      expect(container.read(topicTrackingStateProvider), isEmpty);
    });
  });

  group('增量请求与过期保护', () {
    late ProviderContainer container;
    late _Service service;
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'topic_sort_filter': 'newTopics',
      });
      final prefs = await SharedPreferences.getInstance();
      service = _Service();
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          discourseServiceProvider.overrideWithValue(service),
          topicTrackingStateProvider.overrideWith(_Tracking.new),
          categoryMapProvider.overrideWith(
            (ref) => AsyncData({
              2: Category.fromJson({'id': 2, 'slug': 'dev'}),
            }),
          ),
        ],
      );
      container.read(tabTagsProvider(2).notifier).state = ['dart'];
      container
          .read(topicNewSubsetProvider.notifier)
          .setSubset(NewSubset.replies);
      container
          .read(topicSortOrderProvider.notifier)
          .setOrder(TopicSortOrder.created);
      await container.read(topicListProvider(2).future);
    });
    tearDown(() => container.dispose());

    test('使用当前 new/category/tags/subset/order 获取话题并插入', () async {
      service.incoming = Completer();
      final pending = container.read(topicListProvider(2).notifier).loadBefore([
        11,
      ]);
      expect(service.lastRequest, {
        'filter': 'new',
        'categoryId': 2,
        'tags': ['dart'],
        'order': 'created',
        'ascending': false,
        'subset': 'replies',
        'topicIds': [11],
      });
      service.incoming!.complete(TopicListResponse(topics: [_topic(11)]));
      expect(await pending, [11]);
      expect(container.read(topicListProvider(2)).value!.map((t) => t.id), [
        11,
        10,
      ]);
    });

    test('请求失败向上传递，列表保持原状', () async {
      service.incoming = Completer();
      final pending = container.read(topicListProvider(2).notifier).loadBefore([
        11,
      ]);
      final expectation = expectLater(pending, throwsA(isA<StateError>()));
      service.incoming!.completeError(StateError('offline'));
      await expectation;
      expect(container.read(topicListProvider(2)).value!.map((t) => t.id), [
        10,
      ]);
    });

    test('加载期间切换筛选并刷新，旧请求不能覆盖新列表', () async {
      service.incoming = Completer();
      final notifier = container.read(topicListProvider(2).notifier);
      final pending = notifier.loadBefore([11]);
      container
          .read(topicFilterProvider.notifier)
          .setFilter(TopicListFilter.latest);
      await notifier.refresh();
      service.incoming!.complete(TopicListResponse(topics: [_topic(11)]));
      expect(await pending, isNull);
      expect(container.read(topicListProvider(2)).value!.map((t) => t.id), [
        20,
      ]);
    });
  });
}
