import 'dart:convert';

import 'package:fluxdo/models/sticker.dart';
import 'package:fluxdo/services/sticker_market_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 已订阅分组的元信息缓存。
///
/// 元信息是为了让表情面板首帧不回网络就能画出 tab 栏，但它只是缓存 ——
/// `sticker_subscribed_groups`（id 列表）才是「订阅了什么」的真相。这里
/// 重点锁的就是这条边界：缓存缺失/损坏时订阅本身绝不能丢。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<StickerMarketService> newService([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return StickerMarketService(await SharedPreferences.getInstance());
  }

  StickerGroup group(String id, {String name = '', String icon = ''}) {
    return StickerGroup(
      id: id,
      name: name.isEmpty ? '分组 $id' : name,
      icon: icon,
      order: 0,
      emojiCount: 3,
      isArchived: false,
    );
  }

  test('订阅同时落 id 与元信息，按订阅顺序返回', () async {
    final service = await newService();

    await service.subscribe(group('group-b', name: 'B'));
    await service.subscribe(group('group-a', name: 'A'));

    expect(service.getSubscribedGroupIds(), ['group-b', 'group-a']);
    expect(
      service.getSubscribedGroups().map((g) => g.name),
      ['B', 'A'],
      reason: '展示顺序是订阅顺序，不是 order 字段',
    );
  });

  test('老版本升级：只有 id 没有元信息时，订阅不能丢', () async {
    // 升级前写下的数据只有 id 列表
    final service = await newService({
      'sticker_subscribed_groups': ['group-1', 'group-2'],
    });

    final groups = service.getSubscribedGroups();

    expect(groups.map((g) => g.id), [
      'group-1',
      'group-2',
    ], reason: '元信息缺失只能让 name/icon 留空，不能把已订阅当成未订阅');
    expect(groups.every((g) => g.name.isEmpty), isTrue);
    expect(service.isSubscribed('group-1'), isTrue);
  });

  test('元信息缓存损坏时逐条跳过，不影响其他分组', () async {
    final service = await newService({
      'sticker_subscribed_groups': ['group-1', 'group-2'],
      'sticker_subscribed_group_meta': [
        '{坏 json',
        json.encode(group('group-2', name: '好的').toJson()),
      ],
    });

    final groups = service.getSubscribedGroups();

    expect(groups.map((g) => g.id), ['group-1', 'group-2']);
    expect(groups[0].name, isEmpty, reason: '坏掉那条退化成占位');
    expect(groups[1].name, '好的');
  });

  test('取消订阅连带清掉元信息', () async {
    final service = await newService();
    await service.subscribe(group('group-1'));
    await service.subscribe(group('group-2'));

    await service.unsubscribe('group-1');

    expect(service.getSubscribedGroupIds(), ['group-2']);
    expect(service.getSubscribedGroups().map((g) => g.id), ['group-2']);
    // 重新订阅后仍要能拿到元信息（没有被残留的空壳顶掉）
    await service.subscribe(group('group-1', name: '回来了'));
    expect(
      service.getSubscribedGroups().firstWhere((g) => g.id == 'group-1').name,
      '回来了',
    );
  });

  test('元信息新鲜度只看 name/icon/emojiCount', () async {
    final service = await newService();
    final original = group('group-1', name: 'N', icon: 'I');
    await service.subscribe(original);

    expect(service.isSubscribedMetaFresh(original), isTrue);
    expect(
      service.isSubscribedMetaFresh(original.copyWith(name: '改名了')),
      isFalse,
    );
    expect(
      service.isSubscribedMetaFresh(original.copyWith(emojiCount: 99)),
      isFalse,
    );
    expect(
      service.isSubscribedMetaFresh(group('group-未订阅')),
      isFalse,
      reason: '没有缓存过的分组一律视为不新鲜',
    );
  });

  test('未订阅的分组不会因为写过元信息就出现在列表里', () async {
    final service = await newService();

    await service.cacheSubscribedGroupMeta(group('group-1'));

    expect(service.getSubscribedGroups(), isEmpty);
    expect(service.isSubscribed('group-1'), isFalse);
  });
}
