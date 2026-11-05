import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/avatar_url.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/search_result.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

void main() {
  const template = 'https://cdn.example/user_avatar/site/user/{size}/1.png';
  tearDown(() => PreloadedDataService().reset());

  test('日志中的非标准像素向上选档，标准尺寸保持不变', () {
    for (final pair in {
      40: 48,
      56: 72,
      64: 72,
      120: 144,
      128: 144,
      192: 288,
      96: 96,
    }.entries) {
      expect(
        AvatarUrl.resolve(template, size: pair.key),
        'https://cdn.example/user_avatar/site/user/${pair.value}/1.png',
      );
    }
    expect(AvatarUrl.selectSize(2000), 288);
    expect(AvatarUrl.selectSize(0), 24);
  });

  test('自定义档位去重排序并向上选择，不套用服务端最近档规则', () {
    AvatarUrl.configure('100| 49|98|98');
    expect(AvatarUrl.selectSize(50), 98);
    expect(AvatarUrl.selectSize(97), 98);
    expect(AvatarUrl.selectSize(200), 100);
  });

  test('非法配置回退，混合配置过滤非法值', () {
    for (final value in [null, '', 'bad|0|-2|1001', 144]) {
      AvatarUrl.configure(value);
      expect(AvatarUrl.selectSize(128), 144);
    }
    AvatarUrl.configure('bad|0|64|1001|128');
    expect(AvatarUrl.selectSize(60), 64);
    expect(AvatarUrl.selectSize(96), 128);
  });

  test('预加载配置更新和清空同步到模型入口', () {
    final user = TopicUser(id: 1, username: 'user', avatarTemplate: template);
    final search = SearchPost.fromJson({
      'id': 1,
      'avatar_template': template,
    }, null);
    final service = PreloadedDataService();
    service.debugSeed(siteSettings: {'avatar_sizes': '32|64|128'});
    expect(user.getAvatarUrl(size: 120), contains('/128/'));
    expect(search.getAvatarUrl(), contains('/128/'));
    service.debugSeed(siteSettings: {'avatar_sizes': '48|96|192'});
    expect(user.getAvatarUrl(size: 120), contains('/192/'));
    service.reset();
    expect(user.getAvatarUrl(size: 120), contains('/144/'));
  });

  test('实际 URL、动图和空模板保持原样，查询与片段不被重建', () {
    for (final url in [
      '',
      'https://cdn.example/image.gif?size=128#frame',
      'https://cdn.example/user_avatar/site/user/128/1.png',
    ]) {
      expect(AvatarUrl.resolve(url, size: 64), url);
    }
    expect(
      AvatarUrl.resolve('$template?token=a%2Fb#x', size: 64),
      'https://cdn.example/user_avatar/site/user/72/1.png?token=a%2Fb#x',
    );
  });
}
