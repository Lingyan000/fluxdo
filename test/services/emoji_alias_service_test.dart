/// emoji 别名搜索排序与截断测试。
///
/// 只测纯函数部分([EmojiAliasService.search]),不碰网络 —— 索引通过
/// 反射不到,这里用 `debugSetAliases` 注入。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/emoji_alias_service.dart';

void main() {
  final svc = EmojiAliasService();

  setUp(() {
    svc.debugSetAliases({
      'rofl': ['laugh', 'lol', '笑死', '打滚', '破涕为笑'],
      'joy': ['laugh', 'lol', '笑死', '眼泪'],
      'laughing': ['haha', 'lol', '大笑'],
      'rose': ['flower', '玫瑰'],
      'rocket': ['launch', 'space', '火箭'],
      'heart': ['love', '红心'],
    });
  });

  tearDown(svc.debugReset);

  test('名字完全相等排最前', () {
    final hits = svc.search('rofl');
    expect(hits.first.name, 'rofl');
    expect(hits.first.matchedAlias, isNull);
  });

  test('名字前缀命中优先于别名命中', () {
    final hits = svc.search('ro').map((h) => h.name).toList();
    // rofl/rose/rocket 都是名字前缀命中,排在只靠别名命中的前面
    expect(hits.take(3), containsAll(['rofl', 'rose', 'rocket']));
  });

  test('同级按名字长度升序(短名更常用)', () {
    final hits = svc.search('ro').map((h) => h.name).toList();
    expect(hits.indexOf('rose'), lessThan(hits.indexOf('rocket')));
  });

  test('中文别名可搜,并回带命中的别名', () {
    final hits = svc.search('笑死');
    expect(hits.map((h) => h.name), containsAll(['rofl', 'joy']));
    expect(hits.first.matchedAlias, '笑死');
  });

  test('英文别名完全相等排在名字包含之前', () {
    final hits = svc.search('lol').map((h) => h.name).toList();
    expect(hits, isNotEmpty);
    expect(hits.first, isIn(['joy', 'rofl', 'laughing']));
  });

  test('大小写不敏感', () {
    expect(svc.search('ROFL').first.name, 'rofl');
    expect(svc.search('LoVe').first.name, 'heart');
  });

  test('最多返回 limit 条', () {
    expect(svc.search('l', limit: 5).length, lessThanOrEqualTo(5));
    expect(svc.search('o', limit: 2).length, lessThanOrEqualTo(2));
  });

  test('空查询不返回候选(光敲一个冒号不该糊一屏)', () {
    expect(svc.search(''), isEmpty);
    expect(svc.search('   '), isEmpty);
  });

  test('无匹配返回空', () {
    expect(svc.search('zzzzzz'), isEmpty);
  });

  test('未加载时返回空且 isLoaded=false', () {
    svc.debugReset();
    expect(svc.isLoaded, isFalse);
    expect(svc.search('rofl'), isEmpty);
  });

  group('合法名集合(shortcode 转换用)', () {
    test('认识表里的名字,不认识表外的', () {
      expect(svc.isKnownEmoji('rofl'), isTrue);
      expect(svc.isKnownEmoji('ROFL'), isTrue, reason: '大小写不敏感');
      expect(svc.isKnownEmoji('30'), isFalse, reason: '否则 12:30: 会误转');
      expect(svc.isKnownEmoji('nosuch'), isFalse);
    });

    test('invalidate 只作废搜索索引,合法名集合保留', () {
      svc.invalidate();
      expect(svc.isLoaded, isFalse, reason: '下次敲 : 要重新拉');
      expect(
        svc.isKnownEmoji('rofl'),
        isTrue,
        reason: '作废掉会让 :rofl: 转换时灵时不灵',
      );
    });

    test('没拉到任何数据时一律不认(宁可不转也不裂图)', () {
      svc.debugReset();
      expect(svc.hasKnownNames, isFalse);
      expect(svc.isKnownEmoji('rofl'), isFalse);
    });
  });
}
