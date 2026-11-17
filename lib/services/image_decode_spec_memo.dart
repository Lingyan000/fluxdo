import 'package:flutter/painting.dart';

/// URL → 源图 provider 的会话级备忘。
///
/// 查看器打开时的缩略图占位必须与帖内用**完全相同的 provider 参数**:
/// ImageCache 的 key 是 ResizeImageKey(内层 provider key + 宽高 + 策略),
/// 参数差一点就是 cache miss —— Hero 转场帧白付一次全量解码(帖内那份
/// 明明还在屏、活在缓存里)。帖内路径(LazyImage / 网格瓦片 / 轮播)
/// 构建 provider 时登记，查看器直接复用，保留 bucket、scale、尺寸和策略。
///
/// 纯内存、会话级:查看器只可能从"帖内那张图还在屏"的状态进入,
/// 不需要跨会话持久化。
class ImageDecodeSpecMemo {
  ImageDecodeSpecMemo._();

  // 只持有轻量 provider，不持有图片帧或 ImageStream，不延长纹理生命周期。
  static final Map<String, ImageProvider> _mem = {};
  static const int _cap = 512;

  static T remember<T extends ImageProvider>(String url, T provider) {
    if (url.isEmpty) return provider;
    _mem.remove(url);
    _mem[url] = provider;
    while (_mem.length > _cap) {
      _mem.remove(_mem.keys.first);
    }
    return provider;
  }

  /// 未登记返回 null。
  static ImageProvider? peek(String url) {
    final v = _mem.remove(url);
    if (v != null) _mem[url] = v; // LRU 触摸
    return v;
  }
}
