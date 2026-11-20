import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'mini_app_artwork_image.dart';

/// 卡片背景的图标水印：图标与渐隐遮罩一次性栅格化成位图并按尺寸复用。
/// 滚动时每张卡片只贴一张位图，不再逐帧离屏合成遮罩、重绘矢量路径。
class MiniAppArtworkWatermark extends StatefulWidget {
  const MiniAppArtworkWatermark({
    super.key,
    required this.url,
    required this.size,
  });
  final String url;
  final double size;

  @override
  State<MiniAppArtworkWatermark> createState() =>
      _MiniAppArtworkWatermarkState();
}

class _MiniAppArtworkWatermarkState extends State<MiniAppArtworkWatermark>
    with SingleTickerProviderStateMixin {
  _WatermarkKey? _key;
  ui.Image? _image;
  AnimationController? _fade;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MiniAppArtworkWatermark oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final key = (
      url: widget.url,
      dark: Theme.of(context).brightness == Brightness.dark,
      pixels: (widget.size * MediaQuery.devicePixelRatioOf(context))
          .round()
          .clamp(1, 1024),
    );
    if (key == _key) return;
    _key = key;
    _setImage(_WatermarkCache.peek(key));
    if (_image != null || _WatermarkCache.settled(key)) {
      // 已栅格化过的水印同步恢复，回收重挂载不重复淡入。
      _fade?.value = 1;
      return;
    }
    _WatermarkCache.load(key).then((_) {
      if (!mounted || _key != key) return;
      final image = _WatermarkCache.peek(key);
      if (image == null) return;
      setState(() => _setImage(image));
      // 与网络图片占位到首帧的 200ms 渐显保持一致。
      (_fade ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )).forward(from: 0);
    });
  }

  void _setImage(ui.Image? image) {
    _image?.dispose();
    _image = image;
  }

  @override
  void dispose() {
    _fade?.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.shrink();
    return RawImage(
      image: image,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
      opacity: _fade,
    );
  }
}

typedef _WatermarkKey = ({String url, bool dark, int pixels});

/// 按占用字节淘汰；组件持有各自的克隆句柄，淘汰时不影响正在显示的水印。
abstract final class _WatermarkCache {
  static const _maxBytes = 24 << 20;
  static final _ready = <_WatermarkKey, ui.Image?>{};
  static final _pending = <_WatermarkKey, Future<void>>{};
  static int _bytes = 0;

  /// 返回克隆句柄，由调用方释放。
  static ui.Image? peek(_WatermarkKey key) {
    final image = _ready.remove(key);
    if (image == null) return null;
    _ready[key] = image;
    return image.clone();
  }

  /// 已有结果（含失败）时不再重试，避免损坏图标反复下载解码。
  static bool settled(_WatermarkKey key) => _ready.containsKey(key);

  static Future<void> load(_WatermarkKey key) => _pending[key] ??=
      _bake(key).then(
        (image) => _store(key, image),
        onError: (Object _) => _store(key, null),
      )..whenComplete(() {
        _pending.remove(key);
      });

  static void _store(_WatermarkKey key, ui.Image? image) {
    _remove(key);
    _ready[key] = image;
    _bytes += _cost(image);
    while (_bytes > _maxBytes && _ready.length > 1) {
      _remove(_ready.keys.first);
    }
  }

  static void _remove(_WatermarkKey key) {
    if (!_ready.containsKey(key)) return;
    final image = _ready.remove(key);
    _bytes -= _cost(image);
    image?.dispose();
  }

  static int _cost(ui.Image? image) =>
      image == null ? 0 : image.width * image.height * 4;

  static Future<ui.Image> _bake(_WatermarkKey key) async {
    final size = key.pixels;
    final artwork = await MiniAppArtworkImage.load(
      key.url,
      brightness: key.dark ? Brightness.dark : Brightness.light,
      size: size,
      fit: BoxFit.cover,
    );
    try {
      final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawImage(artwork, Offset.zero, Paint())
        ..drawRect(
          rect,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [
                Colors.white.withValues(alpha: key.dark ? .16 : .10),
                Colors.transparent,
              ],
              stops: const [.05, .85],
            ).createShader(rect),
        );
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(size, size);
      } finally {
        picture.dispose();
      }
    } finally {
      artwork.dispose();
    }
  }
}
