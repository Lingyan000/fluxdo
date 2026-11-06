import 'package:flutter/foundation.dart';

import 'preloaded_data_service.dart';
import '../utils/url_helper.dart';
import '../utils/emoji_shortcodes.dart';

/// Emoji URL 解析器
///
/// 与 Discourse 官方逻辑一致：
/// - 自定义 emoji（如 bili_114）：从预加载数据 `customEmoji` 注册，URL 由服务端提供
/// - 标准 emoji（如 heart、smile）：URL 确定性拼接
///   `/images/emoji/{表情集}/{name}.png`,肤色变体 `{name}/{tone}.png`
/// - 不依赖 `/emojis.json` API（该接口仅供 emoji picker 使用）
///
/// **展示表情集与站点表情集分离**:站点 `emoji_set` 只决定服务端 cooked
/// 里写哪套地址;展示统一用 [displaySet]。回应面板的动态表情
/// ([animatedUrl])只有 Noto 一套,静态图跟着用 Noto 才能全站同一画风。
class EmojiHandler {
  static final EmojiHandler _instance = EmojiHandler._internal();
  factory EmojiHandler() => _instance;
  EmojiHandler._internal();

  /// 展示用的标准 emoji 表情集。
  static const displaySet = 'noto';

  /// 动态表情集:AVIF 动图序列,与 [displaySet] 同一套 Noto 画。
  static const _animatedSet = 'noto_animated';

  /// 图片版本参数(同官方 IMAGE_VERSION)。展示地址统一带同一版本,
  /// cooked 改写与按名拼接两路落到同一个缓存 key。
  static const _imageVersion = '16';

  /// 站点未下发 `emoji_set` 时的回退表情集(官方默认值)。
  static const _defaultSiteSet = 'twitter';

  /// 标准 emoji 图片路径:`/images/emoji/{set}/{name 或 name/tone}.png`。
  static final _standardPathRegex = RegExp(
    r'/images/emoji/([^/?#]+)/([^?#]+)\.png(?:[?#].*)?$',
  );

  static final _toneRegex = RegExp(r'^([^\s:]+):t([1-6])$');

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
  /// 未找到则使用标准 emoji 的确定性路径（[displaySet] 表情集）。
  String getEmojiUrl(String name) {
    final normalized = normalizeEmojiShortcodeName(name);

    // 优先查自定义 emoji（如 bili_114、tsai 等）
    final customUrl = _customEmojiMap?[normalized];
    if (customUrl != null) {
      return UrlHelper.resolveUrlWithCdn(customUrl);
    }

    // 肤色变体 `name:t3` → `name/3`(官方 code.replace(/:t/, "/"))
    final toneMatch = _toneRegex.firstMatch(normalized);
    final path = toneMatch != null
        ? '${toneMatch.group(1)}/${toneMatch.group(2)}'
        : normalized;
    return UrlHelper.resolveUrlWithCdn(_standardPath(displaySet, path));
  }

  /// 标准 emoji 的动态表情地址;自定义 emoji / 肤色变体没有动态版返回 null。
  ///
  /// 动态表情集并非全量(国旗、区域字母等缺图 404),调用方须以 [getEmojiUrl]
  /// 的静态图兜底。
  String? animatedUrl(String name) {
    final normalized = normalizeEmojiShortcodeName(name);
    if (_customEmojiMap?.containsKey(normalized) ?? false) return null;
    if (_toneRegex.hasMatch(normalized)) return null;
    return UrlHelper.resolveUrlWithCdn(
      '/images/emoji/$_animatedSet/$normalized.avif?v=$_imageVersion',
    );
  }

  /// 把任意标准表情集的 emoji 地址改写到 [displaySet](cooked 里的
  /// `/images/emoji/twitter/…` 等)。非标准 emoji 地址原样返回。
  ///
  /// 只改取图地址、不改 cooked —— 编辑往返/序列化看到的仍是服务端原文。
  static String displayUrl(String url) {
    final match = _standardPathRegex.firstMatch(url);
    if (match == null || match.group(1) == displaySet) return url;
    return url.substring(0, match.start) +
        _standardPath(displaySet, match.group(2)!);
  }

  /// [displaySet] 地址缺图(404)时回退的站点表情集地址。
  ///
  /// 展示表情集按规范名存图,部分别名(`cn`/`jp` 等国旗别名)缺图;站点
  /// 表情集别名与规范名都有,回退后至多画风不同,不会裂图。
  static String? fallbackUrl(String url) {
    final match = _standardPathRegex.firstMatch(url);
    if (match == null || match.group(1) != displaySet) return null;
    final siteSet =
        PreloadedDataService().siteSettingsSync?['emoji_set'] as String? ??
        _defaultSiteSet;
    if (siteSet == displaySet) return null;
    return url.substring(0, match.start) +
        _standardPath(siteSet, match.group(2)!);
  }

  static String _standardPath(String set, String path) =>
      '/images/emoji/$set/$path.png?v=$_imageVersion';
}
