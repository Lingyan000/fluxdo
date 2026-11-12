import 'package:fluxdo/models/user_group.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/discourse_url_parser.dart';

void main() {
  test('用户组目录链接保留查询条件并区分详情与无效路径', () {
    for (final url in ['/g', '/groups/', 'https://linux.do/groups']) {
      expect(DiscourseUrlParser.parseGroupDirectory(url), isNotNull);
    }
    final link = DiscourseUrlParser.parseGroupDirectory(
      '/groups?filter=%E5%BC%80%E5%8F%91&type=my&order=user_count&asc=true&username=alice',
    )!;
    expect(link.filter, '开发');
    expect(link.type, 'my');
    expect(link.order, GroupDirectoryOrder.members);
    expect(link.ascending, true);
    expect(link.username, 'alice');
    expect(
      DiscourseUrlParser.parseGroupDirectory('/g?order=name')!.ascending,
      false,
    );
    for (final url in [
      '/g/team',
      '/groups/team/activity',
      '/directory',
      '/groups//',
    ]) {
      expect(DiscourseUrlParser.parseGroupDirectory(url), isNull);
    }
  });
  group('平行视界左栏链接解析', () {
    test('解析分类 ID', () {
      expect(DiscourseUrlParser.parseCategory('/c/develop/42')?.categoryId, 42);
      expect(DiscourseUrlParser.parseCategory('/c/42')?.categoryId, 42);
      expect(
        DiscourseUrlParser.parseCategory(
          'https://linux.do/c/parent/child/42?ascending=true',
        )?.categoryId,
        42,
      );
      expect(DiscourseUrlParser.parseCategory('/chat/c/general/42'), isNull);
      expect(DiscourseUrlParser.parseCategory('/search?q=/c/42'), isNull);
      expect(DiscourseUrlParser.parseCategory('/c/0'), isNull);
    });

    test('解析用户组主页与成员链接', () {
      for (final url in [
        '/g/team',
        '/groups/team/',
        'https://linux.do/g/team/members?filter=alice#top',
      ]) {
        expect(DiscourseUrlParser.parseGroup(url)?.name, 'team');
      }
      expect(
        DiscourseUrlParser.parseGroup('/g/%E5%BC%80%E5%8F%91')?.name,
        '开发',
      );
      for (final url in [
        '/g',
        '/g/',
        '/g/search',
        '/g/new',
        '/g/check-name',
        '/g/team/manage',
        '/g/team/messages',
        '/g/team/activity/unknown',
        '/g/team/permissions/posts',
        '/search?q=/g/team',
        '/g/%FF',
        '/g/a%2Fb',
      ]) {
        expect(DiscourseUrlParser.parseGroup(url), isNull, reason: url);
      }
    });

    test('用户组活动与权限深链保留标签和分类筛选', () {
      final activity = DiscourseUrlParser.parseGroup(
        '/g/team/activity/mentions?category_id=42',
      );
      expect(activity?.section, GroupSection.activity);
      expect(activity?.activityFilter, GroupActivityFilter.mentions);
      expect(activity?.categoryId, 42);
      expect(
        DiscourseUrlParser.parseGroup('/groups/team/permissions')?.section,
        GroupSection.permissions,
      );
      expect(
        DiscourseUrlParser.parseGroup('/g/team/activity')?.activityFilter,
        GroupActivityFilter.posts,
      );
    });

    test('解析并解码标签', () {
      expect(DiscourseUrlParser.parseTag('/tag/flutter'), 'flutter');
      expect(DiscourseUrlParser.parseTag('/tag/%E4%B8%AD%E6%96%87'), '中文');
    });

    test('只把真正的站点根路径识别为首页', () {
      expect(DiscourseUrlParser.isHomepage('/'), isTrue);
      expect(DiscourseUrlParser.isHomepage('https://linux.do/'), isTrue);
      expect(DiscourseUrlParser.isHomepage('/latest'), isFalse);
    });

    test('解析标题中的绝对 URL', () {
      final result = DiscourseUrlParser.parseTitleUrl(
        ' https://example.com/article?id=42#comments ',
      );

      expect(result?.url, 'https://example.com/article?id=42#comments');
      expect(result?.uri.host, 'example.com');
    });

    test('标题包含其它文字或非 HTTP(S) 协议时不解析', () {
      expect(
        DiscourseUrlParser.parseTitleUrl('看这篇 https://example.com/article'),
        isNull,
      );
      expect(
        DiscourseUrlParser.parseTitleUrl('mailto:user@example.com'),
        isNull,
      );
      expect(DiscourseUrlParser.parseTitleUrl('https://'), isNull);
    });

    test('空白标题与相对路径不触发精选链接', () {
      expect(DiscourseUrlParser.parseTitleUrl(''), isNull);
      expect(DiscourseUrlParser.parseTitleUrl('   '), isNull);
      // 相对路径没有 host，不能当精选链接
      expect(DiscourseUrlParser.parseTitleUrl('/t/topic/123'), isNull);
      // javascript: 等危险协议必须拦下
      expect(DiscourseUrlParser.parseTitleUrl('javascript:alert(1)'), isNull);
    });

    test('协议大小写不敏感，且保留原始 URL 形态', () {
      final upper = DiscourseUrlParser.parseTitleUrl('HTTPS://Example.com/A');
      expect(upper, isNotNull);
      // url 保留用户原文（仅 trim），交给服务端规范化
      expect(upper?.url, 'HTTPS://Example.com/A');
      // Uri 会把 host 规范化为小写（路径保留原大小写）
      expect(upper?.uri.host, 'example.com');
      expect(upper?.uri.path, '/A');

      expect(DiscourseUrlParser.parseTitleUrl('http://example.com'), isNotNull);
    });

    test('协议相对 URL 补齐为 https（对齐官方 isAbsoluteUrl）', () {
      final result = DiscourseUrlParser.parseTitleUrl('//example.com/a');

      expect(result, isNotNull);
      // 原文保留，便于与标题比对
      expect(result?.url, '//example.com/a');
      // 对外使用的才是补齐后的绝对 URL
      expect(result?.absoluteUrl, 'https://example.com/a');
    });

    test('absoluteUrl 对已带协议的 URL 保持可用', () {
      final result = DiscourseUrlParser.parseTitleUrl(
        'https://example.com/a?b=1',
      );

      expect(result?.absoluteUrl, 'https://example.com/a?b=1');
    });
  });
}
