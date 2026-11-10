import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_list/topic_list_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Topic topic(
  int id, {
  bool pinned = true,
  bool unseen = true,
  int unread = 0,
  int? lastRead,
}) => Topic(
  id: id,
  title: '话题 $id',
  slug: '$id',
  categoryId: '2',
  postsCount: 5,
  replyCount: 4,
  views: 0,
  likeCount: 0,
  pinned: pinned,
  unseen: unseen,
  unread: unread,
  highestPostNumber: 5,
  lastReadPostNumber: lastRead,
);

class _User extends CurrentUserNotifier {
  @override
  User? build() => User(id: 1, username: 'tester', trustLevel: 1);
}

class _Tracking extends TopicTrackingStateNotifier {
  @override
  Map<int, TrackedTopicState> build() => {};
}

class _Service extends Fake implements DiscourseService {
  List<Topic> topics = [];
  final calls = <Map<String, Object>>[];
  final results = <bool, List<int>>{};
  int? failId;
  Completer<void>? pending;
  @override
  Future<TopicListResponse> getLatestTopics({
    int page = 0,
    String? order,
    bool? ascending,
  }) async => TopicListResponse(topics: topics);
  @override
  Future<List<int>> dismissTopicIds(
    List<int> ids, {
    required bool dismissPosts,
  }) async {
    calls.add({'ids': ids, 'posts': dismissPosts});
    if (ids.contains(failId)) throw StateError('请求失败');
    if (pending != null) await pending!.future;
    return results[dismissPosts] ?? ids;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Service service;
  late ProviderContainer container;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    PreloadedDataService().debugSeed(currentUser: null, siteSettings: null);
    service = _Service();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        discourseServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_User.new),
        topicTrackingStateProvider.overrideWith(_Tracking.new),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<TopicListNotifier> load(List<Topic> topics) async {
    service.topics = topics;
    await container.read(topicListProvider(null).future);
    await Future<void>.delayed(Duration.zero);
    return container.read(topicListProvider(null).notifier);
  }

  List<Topic> items() => container.read(topicListProvider(null)).requireValue;

  test('一键已读只忽略未看过的置顶，保留已读话题的未读回复', () async {
    final notifier = await load([
      topic(1),
      topic(2, unseen: false, unread: 2, lastRead: 3),
      topic(3, pinned: false),
      topic(4, unseen: false, lastRead: 5),
      topic(5),
    ]);
    await notifier.markPinnedTopicsRead(items().take(4).toList());
    expect(service.calls, [
      {
        'ids': [1],
        'posts': false,
      },
    ]);
    expect(items()[0].unseen, isFalse);
    expect(items()[0].lastReadPostNumber, isNull);
    expect(items()[1].unread, 2);
    expect(items()[1].lastReadPostNumber, 3);
    expect(items()[2].unseen, isTrue);
    expect(items().last.unseen, isTrue, reason: '分组外的置顶不能一并忽略');
    expect(container.read(topicTrackingStateProvider)[1]!.isSeen, isTrue);
  });

  test('只有未读回复时不发请求，不修改已读位置', () async {
    final notifier = await load([
      topic(1, unseen: false, unread: 2, lastRead: 3),
    ]);
    await notifier.markPinnedTopicsRead(items());
    expect(service.calls, isEmpty);
    expect(items().single.unread, 2);
    expect(items().single.lastReadPostNumber, 3);
  });

  test('请求失败保持 NEW 标记，重试仍只发送同一批未读话题', () async {
    final notifier = await load([topic(1), topic(2)]);
    service.failId = 2;
    await expectLater(notifier.markPinnedTopicsRead(items()), throwsStateError);
    expect(items().every((topic) => topic.unseen), isTrue);
    service.failId = null;
    await notifier.markPinnedTopicsRead(items());
    expect(service.calls, [
      {
        'ids': [1, 2],
        'posts': false,
      },
      {
        'ids': [1, 2],
        'posts': false,
      },
    ]);
    expect(items().every((topic) => !topic.unseen), isTrue);
  });

  test('只清除服务端确认的 ID，剩余 NEW 可以重试', () async {
    final notifier = await load([topic(1), topic(2)]);
    service.results[false] = [1];
    await notifier.markPinnedTopicsRead(items());
    expect(items()[0].unseen, isFalse);
    expect(items()[1].unseen, isTrue);
    service.results[false] = [2];
    await notifier.markPinnedTopicsRead(items());
    expect(service.calls, [
      {
        'ids': [1, 2],
        'posts': false,
      },
      {
        'ids': [2],
        'posts': false,
      },
    ]);
  });

  test('忽略请求期间真实阅读产生的未读回复和阅读位置保持不变', () async {
    final notifier = await load([topic(1)]);
    service.pending = Completer<void>();
    final done = notifier.markPinnedTopicsRead(items());
    container
        .read(topicTrackingStateProvider.notifier)
        .updateTopicRead(1, 3, 6);
    service.pending!.complete();
    await done;
    expect(items().single.lastReadPostNumber, 3);
    expect(items().single.highestPostNumber, 6);
    expect(items().single.unread, 3);
    expect(items().single.unseen, isFalse);
  });
}
