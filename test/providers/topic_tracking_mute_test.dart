import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

/// 标签静音判定（对齐 Discourse 网页版 hasMutedTags）
///
/// 服务端 payload 里的 tags 是 `[{id: <int>}]`，用户的 muted_tags 是
/// `[{id, name, slug}]`，两边按 id 比对；行为受站点设置
/// remove_muted_tags_from_latest 的三档取值控制。
void main() {
  setUp(() {
    PreloadedDataService().debugSeed(
      currentUser: {
        'muted_tags': [
          {'id': 10, 'name': 'muted-a', 'slug': 'muted-a'},
          {'id': 11, 'name': 'muted-b', 'slug': 'muted-b'},
        ],
      },
      siteSettings: {'remove_muted_tags_from_latest': 'always'},
    );
  });

  tearDown(() {
    PreloadedDataService().debugSeed(currentUser: null, siteSettings: null);
  });

  Map<String, dynamic> payloadWithTags(List<int> ids) => {
        'tags': [
          for (final id in ids) {'id': id},
        ],
      };

  group('always 模式', () {
    test('命中任一静音标签即过滤', () {
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload(
          payloadWithTags([10, 99]),
        ),
        isTrue,
      );
    });

    test('完全不含静音标签则放行', () {
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload(
          payloadWithTags([98, 99]),
        ),
        isFalse,
      );
    });
  });

  group('only_muted 模式', () {
    setUp(() {
      PreloadedDataService().debugSeed(
        currentUser: {
          'muted_tags': [
            {'id': 10},
            {'id': 11},
          ],
        },
        siteSettings: {'remove_muted_tags_from_latest': 'only_muted'},
      );
    });

    test('全部标签都静音才过滤', () {
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload(
          payloadWithTags([10, 11]),
        ),
        isTrue,
      );
    });

    test('混有非静音标签则放行', () {
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload(
          payloadWithTags([10, 99]),
        ),
        isFalse,
      );
    });
  });

  test('never 模式下一律放行', () {
    PreloadedDataService().debugSeed(
      currentUser: {
        'muted_tags': [
          {'id': 10},
        ],
      },
      siteSettings: {'remove_muted_tags_from_latest': 'never'},
    );
    expect(
      TopicTrackingStateNotifier.isMutedByTagsPayload(payloadWithTags([10])),
      isFalse,
    );
  });

  group('边界情况', () {
    test('payload 为 null / 无标签时放行', () {
      expect(TopicTrackingStateNotifier.isMutedByTagsPayload(null), isFalse);
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload({'tags': []}),
        isFalse,
      );
    });

    test('用户没有静音标签时放行', () {
      PreloadedDataService().debugSeed(
        currentUser: {'muted_tags': []},
        siteSettings: {'remove_muted_tags_from_latest': 'always'},
      );
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload(payloadWithTags([10])),
        isFalse,
      );
    });

    test('站点设置缺失时按官方默认值 always 处理', () {
      PreloadedDataService().debugSeed(
        currentUser: {
          'muted_tags': [
            {'id': 10},
          ],
        },
        siteSettings: {},
      );
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload(payloadWithTags([10])),
        isTrue,
      );
    });

    test('纯 ID 数组形态也能解析（防御不同版本/插件的形态差异）', () {
      PreloadedDataService().debugSeed(
        currentUser: {
          'muted_tags': [10, 11],
        },
        siteSettings: {'remove_muted_tags_from_latest': 'always'},
      );
      expect(
        TopicTrackingStateNotifier.isMutedByTagsPayload({
          'tags': [10, 99],
        }),
        isTrue,
      );
    });
  });
}
