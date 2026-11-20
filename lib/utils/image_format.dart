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

/// 按文件头判断是否为 AVIF(ISO BMFF `ftyp`,品牌 avif/avis/mif1/msf1)。
///
/// 必须看内容而不是后缀:CDN 可能用 `.webp`/`.gif` 等后缀返回 AVIF。
bool bytesLookLikeAvif(List<int> bytes) {
  if (bytes.length < 12) return false;
  if (bytes[4] != 0x66 ||
      bytes[5] != 0x74 ||
      bytes[6] != 0x79 ||
      bytes[7] != 0x70) {
    return false;
  }
  final brand = String.fromCharCodes(bytes.sublist(8, 12));
  return brand == 'avif' ||
      brand == 'avis' ||
      brand == 'mif1' ||
      brand == 'msf1';
}

/// AVIF 是否带动画品牌(avis/msf1,主品牌或兼容品牌)。
bool avifLooksAnimated(List<int> bytes) {
  if (!bytesLookLikeAvif(bytes) || bytes.length < 16) return false;
  final boxSize =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  final end = boxSize.clamp(16, bytes.length);
  for (var o = 8; o + 4 <= end; o += 4) {
    if (o == 12) continue; // minor_version
    final brand = String.fromCharCodes(bytes.sublist(o, o + 4));
    if (brand == 'avis' || brand == 'msf1') return true;
  }
  return false;
}

/// 从 AVIF 的 `ispe`(图像空间尺寸)属性读出宽高,只扫描文件头附近;
/// 读不到返回 null。用于不经解码器就拿到尺寸。
(int, int)? avifIntrinsicSize(List<int> bytes) {
  if (!bytesLookLikeAvif(bytes)) return null;
  final limit = bytes.length < 64 * 1024 ? bytes.length : 64 * 1024;
  for (var i = 4; i + 16 <= limit; i++) {
    // 'ispe' 后紧跟 version/flags(4)、width(4)、height(4)
    if (bytes[i] == 0x69 &&
        bytes[i + 1] == 0x73 &&
        bytes[i + 2] == 0x70 &&
        bytes[i + 3] == 0x65) {
      int u32(int o) =>
          (bytes[o] << 24) |
          (bytes[o + 1] << 16) |
          (bytes[o + 2] << 8) |
          bytes[o + 3];
      final width = u32(i + 8);
      final height = u32(i + 12);
      if (width > 0 && height > 0) return (width, height);
    }
  }
  return null;
}
