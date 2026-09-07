import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/providers/sticker_provider.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 已订阅分组元信息的回填（老版本升级自愈 + 改名换图跟随）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SubscribedStickerGroupsNotifier> newNotifier([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    final service = StickerMarketService(await SharedPreferences.getInstance());
    return SubscribedStickerGroupsNotifier(service);
  }

  StickerGroupDetail detail(
    String id, {
    required String name,
    String icon = '',
    int emojiCount = 2,
  }) {
    return StickerGroupDetail(
      id: id,
      name: name,
      icon: icon,
      emojis: [
        for (var i = 0; i < emojiCount; i++)
          StickerItem(
            id: '$id-$i',
            name: 'e$i',
            url: 'https://example.com/$i.webp',
            width: 1,
            height: 1,
            groupId: id,
          ),
      ],
    );
  }

  test('老版本升级：详情到手后把占位补成真名真图', () async {
    final notifier = await newNotifier({
      'sticker_subscribed_groups': ['group-1'],
    });
    expect(notifier.state.single.name, isEmpty, reason: '升级后先是占位');

    await notifier.refreshMetaFromDetail(
      'group-1',
      detail('group-1', name: '藤田言音', icon: 'https://cdn/i.avif'),
    );

    final group = notifier.state.single;
    expect(group.name, '藤田言音');
    expect(group.icon, 'https://cdn/i.avif');
    expect(group.emojiCount, 2, reason: 'emojiCount 取详情里的实际条数');
  });

  test('市场侧改名换图后跟随更新', () async {
    final notifier = await newNotifier();
    await notifier.subscribe(
      StickerGroup(
        id: 'group-1',
        name: '旧名',
        icon: 'old',
        order: 7,
        emojiCount: 3,
        isArchived: false,
      ),
    );

    await notifier.refreshMetaFromDetail(
      'group-1',
      detail('group-1', name: '新名', icon: 'new', emojiCount: 5),
    );

    final group = notifier.state.single;
    expect([group.name, group.icon, group.emojiCount], ['新名', 'new', 5]);
    expect(group.order, 7, reason: '详情不带 order，必须沿用已有缓存值');
  });

  test('未订阅的分组拉到详情也不写进列表', () async {
    final notifier = await newNotifier();

    await notifier.refreshMetaFromDetail(
      'group-未订阅',
      detail('group-未订阅', name: '路过'),
    );

    expect(notifier.state, isEmpty);
  });

  test('元信息已新鲜时重复回填不改变状态', () async {
    final notifier = await newNotifier({
      'sticker_subscribed_groups': ['group-1'],
    });
    await notifier.refreshMetaFromDetail(
      'group-1',
      detail('group-1', name: 'N', icon: 'I'),
    );
    final afterFirst = notifier.state;

    await notifier.refreshMetaFromDetail(
      'group-1',
      detail('group-1', name: 'N', icon: 'I'),
    );

    expect(
      notifier.state,
      same(afterFirst),
      reason: '内容没变就不该写盘、不该发新状态触发 rebuild',
    );
  });

  test('取消订阅后元信息一起消失', () async {
    final notifier = await newNotifier();
    await notifier.subscribe(
      StickerGroup(
        id: 'group-1',
        name: 'N',
        icon: 'I',
        order: 0,
        emojiCount: 1,
        isArchived: false,
      ),
    );

    await notifier.unsubscribe('group-1');

    expect(notifier.state, isEmpty);
    expect(notifier.isSubscribed('group-1'), isFalse);
  });
}
