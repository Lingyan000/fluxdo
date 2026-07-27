import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/hashtag_item.dart';

void main() {
  group('HashtagItem.fromJson(/hashtags/search.json 的一条 result)', () {
    test('分类:取 ref 作插入串、colors 首项作色块', () {
      final item = HashtagItem.fromJson({
        'text': '开发调优',
        'slug': 'dev',
        'ref': 'dev',
        'type': 'category',
        'colors': ['0088CC', 'FFFFFF'],
        'relative_url': '/c/dev/4',
        'id': 4,
      });

      expect(item.kind, HashtagKind.category);
      expect(item.label, '开发调优');
      expect(item.ref, 'dev');
      expect(item.colorHex, '0088CC');
      expect(item.id, 4);
    });

    test('标签:服务端已带好消歧后缀,客户端原样用', () {
      final item = HashtagItem.fromJson({
        'text': 'dev',
        'slug': 'dev',
        'ref': 'dev::tag',
        'type': 'tag',
        'secondary_text': 'x 128',
      });

      expect(item.kind, HashtagKind.tag);
      expect(item.ref, 'dev::tag');
      expect(item.secondaryText, 'x 128');
      expect(item.colorHex, isNull);
    });

    test('icon 字段透传(站点 hashtag_icons,分类可自定义)', () {
      final item = HashtagItem.fromJson({
        'text': '搞七捻三',
        'ref': 'gossip',
        'type': 'category',
        'icon': 'shield-halved',
      });

      expect(item.icon, 'shield-halved');
    });

    test('缺 ref 时退回 slug(过滤空 ref 的判据靠它)', () {
      final item = HashtagItem.fromJson({
        'text': '资源荟萃',
        'slug': 'resource',
        'type': 'category',
      });

      expect(item.ref, 'resource');
    });
  });
}
