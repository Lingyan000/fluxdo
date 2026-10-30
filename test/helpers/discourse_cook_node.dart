import 'dart:convert';
import 'dart:io';

// 使用项目真实 bundle，所有调用数据由测试构造。
Future<Map<String, dynamic>> parseWithNode(
  String raw, {
  bool footnotes = false,
  Map<String, dynamic> siteSettings = const {},
}) async {
  final result = await Process.run('node', [
    '-e',
    '''
const fs = require('fs');
eval(fs.readFileSync('assets/cook/discourse-cook.js', 'utf8'));
__fluxdoCook.init(JSON.stringify({
  siteSettings: {
    enable_markdown_footnotes: $footnotes,
    spoiler_enabled: true, enable_emoji: true, discourse_local_dates_enabled: true, poll_enabled: true, checklist_enabled: true,
    enable_markdown_linkify: true,
    markdown_linkify_tlds: 'com|net|org|io|dev|me|do',
    traditional_markdown_linebreaks: false,
    max_image_width: 690, max_image_height: 500,
    ...JSON.parse(process.argv[2])
  },
  site: {categories: [], hashtag_configurations: {}},
  customEmoji: [], baseUri: 'https://example.com'
}));
process.stdout.write(__fluxdoCook.parseForEditor(JSON.parse(process.argv[1])));
''',
    jsonEncode(raw),
    jsonEncode(siteSettings),
  ]);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

Future<String> cookWithNode(
  String raw, {
  bool footnotes = false,
  Map<String, dynamic> siteSettings = const {},
}) async {
  final result = await Process.run('node', [
    '-e',
    '''
const fs = require('fs');
eval(fs.readFileSync('assets/cook/discourse-cook.js', 'utf8'));
__fluxdoCook.init(JSON.stringify({
  siteSettings: {
    enable_markdown_footnotes: $footnotes,
    spoiler_enabled: true, enable_emoji: true, discourse_local_dates_enabled: true, poll_enabled: true, checklist_enabled: true,
    enable_markdown_linkify: true,
    markdown_linkify_tlds: 'com|net|org|io|dev|me|do',
    traditional_markdown_linebreaks: false,
    max_image_width: 690, max_image_height: 500,
    ...JSON.parse(process.argv[2])
  },
  site: {categories: [], hashtag_configurations: {}},
  customEmoji: [], baseUri: 'https://example.com'
}));
process.stdout.write(__fluxdoCook.cook(JSON.parse(process.argv[1])));
''',
    jsonEncode(raw),
    jsonEncode(siteSettings),
  ]);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  return result.stdout as String;
}
