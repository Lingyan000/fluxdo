import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 预览用 HTML 截断结果
class HtmlPreview {
  final String html;

  /// 是否丢弃了原文的一部分
  final bool truncated;

  const HtmlPreview(this.html, {required this.truncated});
}

/// 预览场景的 HTML 截断:只保留开头够展示的部分,避免整段长文构建排版后
/// 只露出几行。
///
/// 深度优先保留节点,两份预算任一耗尽即停:
/// - 可见文字 [maxText]:决定预览能填满多少行
/// - 标记 [maxMarkup](标签名 + 属性长度):兜住图片、附件等几乎没有文字的内容
///
/// 耗尽处截断文本节点,其后的节点全部丢弃;结果由 DOM 序列化,标签始终闭合。
class HtmlPreviewTruncator {
  static const int _cacheCap = 32;
  static final _cache = <(int, int, int), HtmlPreview>{};

  static HtmlPreview truncate(
    String html, {
    required int maxText,
    required int maxMarkup,
  }) {
    // 文字与标记都不会超过原文长度
    if (html.length <= maxText && html.length <= maxMarkup) {
      return HtmlPreview(html, truncated: false);
    }

    final key = (html.hashCode, maxText, maxMarkup);
    final cached = _cache.remove(key);
    if (cached != null) return _cache[key] = cached;

    final result = _truncate(html, maxText: maxText, maxMarkup: maxMarkup);
    _cache[key] = result;
    if (_cache.length > _cacheCap) _cache.remove(_cache.keys.first);
    return result;
  }

  static HtmlPreview _truncate(
    String html, {
    required int maxText,
    required int maxMarkup,
  }) {
    final fragment = html_parser.parseFragment(html);
    var text = 0;
    var markup = 0;
    var exhausted = false;

    void visit(dom.Node parent) {
      for (final child in List.of(parent.nodes)) {
        if (exhausted) {
          child.remove();
          continue;
        }
        if (child is dom.Text) {
          final data = child.data;
          final remain = maxText - text;
          if (data.length <= remain) {
            text += data.length;
          } else {
            child.data = _cutText(data, remain);
            exhausted = true;
          }
        } else if (child is dom.Element) {
          var cost = child.localName?.length ?? 0;
          child.attributes.forEach((name, value) {
            cost += name.toString().length + value.length;
          });
          // 第一个节点即使超预算也保留,保证预览不为空
          final keptAny = text > 0 || markup > 0;
          if (keptAny && markup + cost > maxMarkup) {
            child.remove();
            exhausted = true;
            continue;
          }
          markup += cost;
          visit(child);
        }
      }
    }

    visit(fragment);
    if (!exhausted) return HtmlPreview(html, truncated: false);
    return HtmlPreview(fragment.outerHtml, truncated: true);
  }

  /// 截到 [length] 以内:有换行时停在最后一个换行(代码不留半行),
  /// 并避开 UTF-16 代理对的中间
  static String _cutText(String data, int length) {
    if (length <= 0) return '';
    var end = length;
    final newline = data.lastIndexOf('\n', end - 1);
    if (newline > 0) {
      end = newline;
    } else if (_isLowSurrogate(data.codeUnitAt(end))) {
      end--;
    }
    return data.substring(0, end);
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
}
