/// 需要经过原生动图管线的 URL 类型。WebP 也可能是静态图，
/// 仍沿用原生管线的内容嗅探；此处不把文件后缀当作实际动画证明。
bool isNativeAnimatedUrl(String url) {
  try {
    final path = Uri.parse(url).path.toLowerCase();
    return path.endsWith('.gif') ||
        path.endsWith('.apng') ||
        path.endsWith('.webp');
  } catch (_) {
    return false;
  }
}
