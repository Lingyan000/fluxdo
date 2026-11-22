import 'dart:convert' show jsonEncode;

/// 给验证主文档的画布配色。页面可能在脚本运行后才创建或替换 body。
String cfVerificationPagePaletteScript({
  required Uri page,
  required String surface,
  required String text,
}) =>
    '''
(function() {
  if (window !== window.top || location.origin !== ${jsonEncode(page.origin)} ||
      location.pathname !== ${jsonEncode(page.path)}) return false;
  if (!window.__fluxdoSetCfPagePalette) {
    var background, foreground;
    function paintCanvas() {
      var root = document.documentElement;
      if (!root) return;
      observer.observe(root, {childList: true});
      [root, document.body].forEach(function(element) {
        if (!element) return;
        element.style.setProperty('background-color', background, 'important');
        element.style.setProperty('color', foreground, 'important');
      });
    }
    var observer = new MutationObserver(paintCanvas);
    observer.observe(document, {childList: true});
    window.__fluxdoSetCfPagePalette = function(surface, text) {
      background = surface;
      foreground = text;
      window.__fluxdoCfMaskColor = surface;
      var mask = document.getElementById('__fluxdoCfMask');
      if (mask) mask.style.setProperty('background-color', surface, 'important');
      paintCanvas();
    };
  }
  window.__fluxdoSetCfPagePalette(${jsonEncode(surface)}, ${jsonEncode(text)});
  return true;
})();
''';
