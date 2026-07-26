import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'preloaded_data_service.dart';
import '../utils/url_helper.dart';
import '../utils/emoji_shortcodes.dart';

/// Emoji URL 解析器
///
/// 与 Discourse 官方逻辑一致：
/// - 自定义 emoji（如 bili_114）：从预加载数据 `customEmoji` 注册，URL 由服务端提供
/// - 标准 emoji（如 heart、smile）：URL 确定性拼接 `/images/emoji/twitter/{name}.png`
/// - 不依赖 `/emojis.json` API（该接口仅供 emoji picker 使用）
class EmojiHandler {
  static final EmojiHandler _instance = EmojiHandler._internal();
  factory EmojiHandler() => _instance;
  EmojiHandler._internal();

  /// 自定义 emoji 名称 -> URL 映射（对应 Discourse 的 extendedEmojiMap）
  Map<String, String>? _customEmojiMap;

  /// 从预加载数据注册自定义 emoji
  ///
  /// 必须在 [PreloadedDataService().ensureLoaded()] 之后调用。
  void init() {
    if (_customEmojiMap != null) return;

    _customEmojiMap = {};

    try {
      final customEmojis = PreloadedDataService().customEmoji;
      if (customEmojis != null) {
        for (final emoji in customEmojis) {
          final name = emoji['name'] as String?;
          final url = emoji['url'] as String?;
          if (name != null && url != null) {
            _customEmojiMap![name] = url;
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load custom emojis: $e');
    }
  }

  /// 将文本中的 :emoji: 替换为 HTML img 标签
  String replaceEmojis(String text) {
    return text.replaceAllMapped(emojiShortcodeRegex, (match) {
      final name = normalizeEmojiShortcodeName(match.group(1)!);
      final fullUrl = getEmojiUrl(name);
      return '<img src="$fullUrl" alt=":$name:" class="emoji" title=":$name:">';
    });
  }

  /// 获取 emoji 的完整 URL
  ///
  /// 优先查找自定义 emoji（有服务端提供的真实 URL），
  /// 未找到则使用标准 emoji 的确定性路径。
  String getEmojiUrl(String name) {
    final normalized = normalizeEmojiShortcodeName(name);

    // 优先查自定义 emoji（如 bili_114、tsai 等）
    final customUrl = _customEmojiMap?[normalized];
    if (customUrl != null) {
      return UrlHelper.resolveUrlWithCdn(customUrl);
    }

    final toneMatch = RegExp(r'^([^\s:]+):t([1-6])$').firstMatch(normalized);
    if (toneMatch != null) {
      final base = toneMatch.group(1)!;
      final tone = toneMatch.group(2)!;
      return UrlHelper.resolveUrlWithCdn(
        '/images/emoji/twitter/$base/t$tone.png?v=12',
      );
    }

    // 标准 emoji，URL 确定性拼接（与 Discourse buildEmojiUrl 一致）
    return UrlHelper.resolveUrlWithCdn(
      '/images/emoji/twitter/$normalized.png?v=12',
    );
  }

  // ---- Unicode emoji → 站内图片 ----
  //
  // Windows 的 Segoe UI Emoji 缺新版 emoji(🫨 等)会渲染成方块(tofu)。
  // Discourse cook 过的 HTML 服务端已换成 <img class="emoji">,但 boost
  // 弹幕/用户名等**纯文本渲染路径**里的裸 Unicode emoji 仍走系统字体。
  // 这里带一份 Discourse 官方的 unicode→shortcode 对照表
  // (assets/emoji/unicode_replacements.json,来自 pretty-text 的
  // `replacements`),让这些路径也统一用站内 emoji 图片。

  Map<String, String>? _unicodeMap;
  int _unicodeMaxUnits = 0;
  bool _unicodeLoading = false;

  /// 触发对照表懒加载(异步,加载完成前 [matchUnicodeEmoji] 返回 null,
  /// 文本按原样渲染,下一帧起生效)。
  void ensureUnicodeMapLoaded() {
    if (_unicodeMap != null || _unicodeLoading) return;
    _unicodeLoading = true;
    rootBundle.loadString('assets/emoji/unicode_replacements.json').then((s) {
      final map = (jsonDecode(s) as Map).cast<String, String>();
      var maxUnits = 0;
      for (final k in map.keys) {
        if (k.length > maxUnits) maxUnits = k.length;
      }
      _unicodeMap = map;
      _unicodeMaxUnits = maxUnits;
    }).catchError((Object e) {
      debugPrint('[EmojiHandler] 加载 unicode emoji 对照表失败: $e');
      _unicodeLoading = false;
    });
  }

  /// 在 [text] 的 [start](UTF-16 下标)处做**最长匹配**。
  /// 命中返回 (shortcode 名, 消耗的 code unit 数);未命中返回 null。
  (String, int)? matchUnicodeEmoji(String text, int start) {
    final map = _unicodeMap;
    if (map == null) return null;
    var maxEnd = start + _unicodeMaxUnits;
    if (maxEnd > text.length) maxEnd = text.length;
    for (var end = maxEnd; end > start; end--) {
      final name = map[text.substring(start, end)];
      if (name != null) return (name, end - start);
    }
    return null;
  }

  /// [start] 处的 code unit 是否可能是 emoji 序列开头(粗筛,避免对
  /// ASCII/中文逐字符做 substring 查表)。
  static bool maybeEmojiStart(int codeUnit) {
    return codeUnit >= 0x2000 && codeUnit < 0x3300 || // 符号/装饰区
        (codeUnit & 0xFC00) == 0xD800 || // 高代理(所有 SMP emoji)
        codeUnit == 0x00A9 || // ©
        codeUnit == 0x00AE; // ®
  }
}
