import 'package:flutter/foundation.dart';

import 'discourse/discourse_service.dart';
import '../constants.dart';
import '../utils/url_helper.dart';

class EmojiHandler {
  static final EmojiHandler _instance = EmojiHandler._internal();
  factory EmojiHandler() => _instance;
  EmojiHandler._internal();

  Map<String, String>? _emojiMap; // name -> url

  /// 加载所有表情并建立索引
  Future<void> init() async {
    if (_emojiMap != null) return;

    try {
      final groups = await DiscourseService().getEmojis();
      _emojiMap = {};

      for (final list in groups.values) {
        for (final emoji in list) {
          _emojiMap![emoji.name] = emoji.url;
        }
      }
    } catch (e) {
      // 即使加载失败，也保证 _emojiMap 不为空，避免后续空指针
      _emojiMap = {};
      debugPrint('Failed to load emojis for handler: $e');
    }
  }

  /// 将文本中的 :emoji: 替换为 HTML img 标签
  String replaceEmojis(String text) {
    // 匹配 :something:
    final regex = RegExp(r':([a-zA-Z0-9_+-]+):');

    return text.replaceAllMapped(regex, (match) {
      final name = match.group(1);

      // 尝试从 emoji map 中获取 URL
      String? url = _emojiMap?[name];

      // 如果找不到，使用备用的 Twitter emoji URL
      url ??= '/images/emoji/twitter/$name.png?v=12';

      final fullUrl = UrlHelper.resolveUrl(url);
      // 使用 class="emoji" 方便 CSS 或 WidgetFactory 识别
      return '<img src="$fullUrl" alt=":$name:" class="emoji" title=":$name:">';
    });
  }

  /// 获取 emoji 的完整 URL
  String getEmojiUrl(String name) {
    final url = _emojiMap?[name];
    if (url != null) {
      return UrlHelper.resolveUrl(url);
    }
    // 备用方案：使用 Twitter emoji
    return '${AppConstants.baseUrl}/images/emoji/twitter/$name.png?v=12';
  }
}
