import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 网页对安全区的声明与实测：是否 `viewport-fit=cover`、原生 `env()` 值、页面底色。
///
/// 由注入脚本在加载、尺寸变化、`<meta>` 与主题切换时上报。
@immutable
class BrowserPageSafeArea {
  const BrowserPageSafeArea({
    required this.cover,
    required this.env,
    this.background,
    this.canvas,
  });

  /// 网页声明了 `viewport-fit=cover`，会用 `env(safe-area-inset-*)` 自己避让。
  final bool cover;

  /// 网页内实测的 `env(safe-area-inset-*)`，单位为 CSS 像素。
  final EdgeInsets env;

  /// 网页在 html 或 body 上声明的底色；未声明或全透明时为 null，需要截图取色。
  final Color? background;

  /// 浏览器默认画布色（CSS `Canvas`，随 color-scheme 变化），取色失败时兜底。
  final Color? canvas;

  static BrowserPageSafeArea? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final env = raw['env'];
    if (env is! List || env.length != 4) return null;
    final values = [for (final value in env) _number(value)];
    if (values.contains(null)) return null;
    return BrowserPageSafeArea(
      cover: raw['cover'] == true,
      env: EdgeInsets.fromLTRB(values[0]!, values[1]!, values[2]!, values[3]!),
      background: _color(raw['background']),
      canvas: _color(raw['canvas']),
    );
  }

  static double? _number(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

  static Color? _color(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    final channels = [for (final value in raw) _number(value)];
    if (channels.contains(null)) return null;
    // 半透明底色叠在 WebView 默认画布上，留白处按不透明处理即可。
    return Color.fromARGB(
      255,
      channels[0]!.round().clamp(0, 255),
      channels[1]!.round().clamp(0, 255),
      channels[2]!.round().clamp(0, 255),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BrowserPageSafeArea &&
      other.cover == cover &&
      other.env == env &&
      other.background == background &&
      other.canvas == canvas;

  @override
  int get hashCode => Object.hash(cover, env, background, canvas);
}

/// 网页区域与系统不安全区的重叠部分。
///
/// 可见的浏览器栏会吃掉自己那一侧的安全区；栏隐藏后，那一侧重新交给网页处理。
/// 键盘弹出时 [MediaQueryData.padding] 底部已归零，不必单独处理。
EdgeInsets browserViewportUnsafeInsets(
  EdgeInsets padding, {
  required bool topChrome,
  required bool bottomChrome,
}) => EdgeInsets.fromLTRB(
  padding.left,
  topChrome ? 0 : padding.top,
  padding.right,
  bottomChrome ? 0 : padding.bottom,
);

/// 决定网页铺满到边缘还是由应用留出安全边距。
///
/// 声明 cover 的网页铺满，由网页用 `env()` 自己避让；其余网页由应用留边。
/// 老版 Android WebView（Chromium 140 以前）等引擎给出的 `env()` 不可靠，
/// 实测与应用算出的遮挡对不上时退回留边。WebView 引擎全进程共用，结论按进程记住。
abstract final class BrowserSafeAreaPolicy {
  static bool? _nativeEnvReliable;

  /// null 表示还没有可比较的样本。
  static bool? get nativeEnvReliable => _nativeEnvReliable;

  static bool edgeToEdge(BrowserPageSafeArea? page) =>
      page?.cover == true && _nativeEnvReliable != false;

  /// 比较应用算出的遮挡与网页实测的 `env()`；没有被遮挡的边时无法判断，返回 null。
  static bool? matches(EdgeInsets expected, EdgeInsets observed) {
    if (expected == EdgeInsets.zero) return null;
    bool near(double a, double b) => (a - b).abs() <= 1.5;
    return near(expected.left, observed.left) &&
        near(expected.top, observed.top) &&
        near(expected.right, observed.right) &&
        near(expected.bottom, observed.bottom);
  }

  static void record({required bool reliable}) => _nativeEnvReliable = reliable;

  @visibleForTesting
  static void resetForTest() => _nativeEnvReliable = null;
}

/// 安全区探针：注入页面，并提供 [measureSource] 供应用主动读取。
abstract final class BrowserSafeAreaProbe {
  static const handlerName = 'fluxdoSafeArea';

  /// 返回与上报相同结构的对象；脚本未注入时为 null。
  static const measureSource =
      'window.__fluxdoSafeArea ? window.__fluxdoSafeArea.measure() : null';

  /// 让脚本忽略去重，重新上报一次（用于接回保活的网页）。
  static const reportSource =
      'window.__fluxdoSafeArea && window.__fluxdoSafeArea.report()';

  static final userScript = UserScript(
    source: _source,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
    forMainFrameOnly: true,
  );

  // 探针挂在 html 下、测完即移除，不进入 body，避免影响页面选择器；
  // 只监听 head 子树与 html/body 自身属性，不跟随正文 DOM 变化。
  static const _source =
      '''
(function () {
  if (window.__fluxdoSafeArea) return;
  var last = '';
  var timer = 0;
  function cover() {
    var metas = document.querySelectorAll('meta[name="viewport"]');
    var content = metas.length ? metas[metas.length - 1].getAttribute('content') || '' : '';
    return /viewport-fit\\s*=\\s*cover/i.test(content);
  }
  function rgba(value) {
    var match = /^rgba?\\(([^)]+)\\)\$/.exec(value || '');
    if (!match) return null;
    var parts = match[1].split(/[\\s,\\/]+/).filter(Boolean).map(parseFloat);
    if (parts.length < 3 || parts.some(isNaN)) return null;
    var alpha = parts.length > 3 ? parts[3] : 1;
    return alpha > 0 ? [parts[0], parts[1], parts[2], alpha] : null;
  }
  function measure() {
    var root = document.documentElement;
    if (!root) return null;
    var probe = document.createElement('div');
    probe.style.cssText = 'position:fixed;top:0;left:0;width:0;height:0;' +
      'visibility:hidden;pointer-events:none;background-color:Canvas;' +
      'padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) ' +
      'env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)';
    root.appendChild(probe);
    var style = getComputedStyle(probe);
    var result = {
      cover: cover(),
      env: [style.paddingLeft, style.paddingTop, style.paddingRight, style.paddingBottom]
        .map(function (value) { return parseFloat(value) || 0; }),
      background: rgba(getComputedStyle(root).backgroundColor) ||
        (document.body && rgba(getComputedStyle(document.body).backgroundColor)),
      canvas: rgba(style.backgroundColor)
    };
    root.removeChild(probe);
    return result;
  }
  function flush() {
    timer = 0;
    var bridge = window.flutter_inappwebview;
    if (!bridge || !bridge.callHandler) return;
    var data = measure();
    if (!data) return;
    var key = JSON.stringify(data);
    if (key === last) return;
    last = key;
    bridge.callHandler('$handlerName', data);
  }
  function schedule() {
    if (!timer) timer = setTimeout(flush, 60);
  }
  window.__fluxdoSafeArea = {
    measure: measure,
    report: function () { last = ''; schedule(); }
  };
  ['resize', 'load', 'pageshow', 'flutterInAppWebViewPlatformReady'].forEach(function (name) {
    window.addEventListener(name, schedule);
  });
  if (window.MutationObserver) {
    var observer = new MutationObserver(schedule);
    var attributes = { attributes: true, attributeFilter: ['class', 'style'] };
    if (document.head) {
      observer.observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['content'] });
    }
    observer.observe(document.documentElement, attributes);
    if (document.body) observer.observe(document.body, attributes);
  }
  if (window.matchMedia) {
    var scheme = window.matchMedia('(prefers-color-scheme: dark)');
    if (scheme.addEventListener) scheme.addEventListener('change', schedule);
    else if (scheme.addListener) scheme.addListener(schedule);
  }
  schedule();
})();
''';
}
