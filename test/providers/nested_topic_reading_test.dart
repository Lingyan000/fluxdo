import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/models/nested_topic.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/nested_reading_provider.dart';
import 'package:fluxdo/providers/nested_topic_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

Post post(int number) => Post(
  id: number,
  username: 'tester',
  avatarTemplate: '',
  cooked: '<p>$number</p>',
  postNumber: number,
  postType: 1,
  updatedAt: DateTime(2026),
  createdAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
);
NestedNode node(int number, [List<NestedNode> children = const []]) =>
    NestedNode(post: post(number), children: children);

class Service extends Fake implements DiscourseService {
  final requests = <(String, int, String)>[];
  bool failSort = false;
  bool missing = false;
  bool truncated = false;
  @override
  Future<NestedRootsResponse> getNestedRoots(
    int topicId, {
    String sort = 'old',
    int page = 0,
    bool trackVisit = false,
  }) async {
    requests.add(('roots', page, sort));
    if (sort == 'top' && failSort) throw StateError('offline');
    return NestedRootsResponse(
      roots: page == 0
          ? [node(2)]
          : missing
          ? []
          : [
              node(3, [node(4)]),
            ],
      hasMoreRoots: page == 0,
      page: page,
      sort: sort,
    );
  }

  @override
  Future<NestedContextResponse> getNestedContext(
    int topicId,
    int postNumber, {
    String sort = 'old',
    bool trackVisit = false,
  }) async {
    requests.add(('context', postNumber, sort));
    if (postNumber == 20) {
      return NestedContextResponse(
        ancestorChain: [post(truncated ? 10 : 3)],
        ancestorsTruncated: truncated,
        targetPost: node(20),
      );
    }
    return NestedContextResponse(
      ancestorChain: [post(3)],
      targetPost: node(10),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<ProviderContainer> containerFor(
    Service service, {
    String sort = 'old',
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = NestedReadingStore(
      await SharedPreferences.getInstance(),
      'alice',
    );
    await store.setSort(sort);
    final container = ProviderContainer(
      overrides: [
        discourseServiceProvider.overrideWithValue(service),
        nestedReadingStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(() {
      container.dispose();
      store.dispose();
    });
    return container;
  }

  test('完整讨论恢复深层目标，按页查找根分支并保留已有兄弟回复', () async {
    final service = Service();
    final container = await containerFor(service);
    const params = NestedTopicParams(topicId: 1, instanceId: 'first');
    final subscription = container.listen(
      nestedTopicProvider(params),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(nestedTopicProvider(params).future);
    final path = await container
        .read(nestedTopicProvider(params).notifier)
        .revealPost(20);
    expect(path, [3, 20]);
    final state = container.read(nestedTopicProvider(params)).requireValue;
    expect(state.contextMode, isFalse);
    expect(state.roots.map((node) => node.post.postNumber), [2, 3]);
    expect(state.roots.last.children.map((node) => node.post.postNumber), [
      4,
      20,
    ]);
    expect(service.requests, [
      ('roots', 0, 'old'),
      ('context', 20, 'old'),
      ('roots', 1, 'old'),
    ]);
  });

  test('祖先链被截断时向上补全，合并后不会重复目标', () async {
    final service = Service()..truncated = true;
    final container = await containerFor(service);
    const params = NestedTopicParams(topicId: 1);
    final subscription = container.listen(
      nestedTopicProvider(params),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(nestedTopicProvider(params).future);
    final notifier = container.read(nestedTopicProvider(params).notifier);
    expect(await notifier.revealPost(20), [3, 10, 20]);
    expect(await notifier.revealPost(20), [3, 10, 20]);
    final roots = container
        .read(nestedTopicProvider(params))
        .requireValue
        .roots;
    expect(
      roots.last.children.where((node) => node.post.postNumber == 10).length,
      1,
    );
  });

  test('目标被删除或分页无进展时停止，完整讨论仍可继续浏览', () async {
    final service = Service()..missing = true;
    final container = await containerFor(service);
    const params = NestedTopicParams(topicId: 1);
    final subscription = container.listen(
      nestedTopicProvider(params),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(nestedTopicProvider(params).future);
    await expectLater(
      container.read(nestedTopicProvider(params).notifier).revealPost(20),
      throwsStateError,
    );
    expect(service.requests.length, 3);
    expect(
      container
          .read(nestedTopicProvider(params))
          .requireValue
          .roots
          .single
          .post
          .postNumber,
      2,
    );
  });

  test('排序失败保留当前讨论，通知定位与新实例遵循保存的排序', () async {
    final service = Service()..failSort = true;
    final container = await containerFor(service, sort: 'new');
    const params = NestedTopicParams(topicId: 1);
    final subscription = container.listen(
      nestedTopicProvider(params),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(nestedTopicProvider(params).future);
    await expectLater(
      container.read(nestedTopicProvider(params).notifier).changeSort('top'),
      throwsStateError,
    );
    expect(
      container.read(nestedTopicProvider(params)).requireValue.sort,
      'new',
    );
    const contextParams = NestedTopicParams(
      topicId: 1,
      targetPostNumber: 20,
      instanceId: 'notice',
    );
    final contextSub = container.listen(
      nestedTopicProvider(contextParams),
      (_, _) {},
    );
    addTearDown(contextSub.close);
    await container.read(nestedTopicProvider(contextParams).future);
    expect(service.requests.last, ('context', 20, 'new'));
    expect(params == contextParams, isFalse);
  });
}
