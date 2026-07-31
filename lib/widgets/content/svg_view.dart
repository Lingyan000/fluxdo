import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../services/blob_image_cache.dart';
import '../../services/media_geometry_memo.dart';
import '../../utils/svg_utils.dart';
import 'animated_svg_view.dart';

/// url → 嗅探/解析产物会话级缓存:sliver 回收重挂载零 IO 零重解析。
/// (ScalableImage 不可变可共享;动画源串交给 AnimatedSvgView,其内部
/// 另有首帧快照的内存 LRU + 磁盘层。)
class _SvgContentCache {
  static final Map<String, _SvgEntry> _entries = <String, _SvgEntry>{};
  static const int _capCount = 24;
  static const int _capBytes = 12 << 20;
  static int _bytes = 0;

  static _SvgEntry? get(String url) {
    final e = _entries.remove(url);
    if (e != null) _entries[url] = e; // LRU 触摸
    return e;
  }

  static void put(String url, _SvgEntry e) {
    final old = _entries.remove(url);
    if (old != null) _bytes -= old.cost;
    _entries[url] = e;
    _bytes += e.cost;
    while (_entries.length > _capCount || _bytes > _capBytes) {
      final k = _entries.keys.first;
      _bytes -= _entries.remove(k)!.cost;
    }
  }
}

class _SvgEntry {
  final String? animatedSource; // 动画 SVG:原始源码
  final ScalableImage? si; // 静态 SVG:解析产物
  final int cost;

  const _SvgEntry.animated(String source)
      : animatedSource = source,
        si = null,
        cost = source.length * 2;

  _SvgEntry.static_(ScalableImage this.si)
      : animatedSource = null,
        cost = 64 << 10; // 粗估,静态图通常很小

  const _SvgEntry.error()
      : animatedSource = null,
        si = null,
        cost = 0;

  bool get isError => animatedSource == null && si == null;
}

/// utf8 解码 + 动画嗅探;顶层函数以便大文件走 compute() 不阻塞 UI isolate。
(bool, String) _sniffSvgTask(Uint8List bytes) {
  final content = SvgUtils.decodeSvgBytes(bytes);
  return (AnimatedSvgView.hasAnimations(content), content);
}

/// 网络 SVG 的统一入口:下载 → 按内容嗅探动画 → 路由。
///
/// - 静态 SVG → [SvgUtils.sanitize] + jovial_svg(轻、成熟);
/// - 动画 SVG(CSS @keyframes/SMIL)→ [AnimatedSvgView]
///   (full_svg_flutter,首帧快照缓存 + 点击播放 + 防注入剥离)。
///
/// 所有"URL 形态"的不可信内容 SVG 共用此件:帖内 `<img src="*.svg">`、
/// 用户签名、DiscourseImage、图片查看器 fallback。内联 `<svg>` 源码
/// 已在手,不需要下载,由 FluxdoRenderCallbacks 直接做同样的路由。
class DiscourseSvgView extends StatefulWidget {
  /// 已解析好的图片地址(upload:// 解析、CDN 重写由调用方完成)。
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 动画形态下画面的对齐(帖子流左对齐,查看器居中)。
  final Alignment alignment;

  /// 动画形态挂载即播(仅查看器等用户主动打开的场景)。
  final bool autoPlayAnimated;

  final WidgetBuilder? placeholderBuilder;
  final WidgetBuilder? errorBuilder;

  const DiscourseSvgView({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.centerLeft,
    this.autoPlayAnimated = false,
    this.placeholderBuilder,
    this.errorBuilder,
  });

  @override
  State<DiscourseSvgView> createState() => _DiscourseSvgViewState();
}

class _DiscourseSvgViewState extends State<DiscourseSvgView> {

  /// 大文件门槛:utf8 解码+动画嗅探全量扫描挪 isolate。
  static const int _bigFileBytes = 256 << 10;

  ScalableImage? _si;
  String? _animatedSource;
  bool _error = false;
  Brightness? _brightness;

  String get _cacheKey =>
      '${widget.url}|${_brightness == Brightness.dark ? 'd' : 'l'}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首次挂载与主题切换都从这里驱动:prefers-color-scheme 求值结果
    // 随亮暗不同,缓存键含主题,切主题即重载出对应配色。
    final b = Theme.of(context).brightness;
    if (b != _brightness) {
      _brightness = b;
      _si = null;
      _animatedSource = null;
      _error = false;
      _restoreOrLoad();
    }
  }

  @override
  void didUpdateWidget(covariant DiscourseSvgView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _si = null;
      _animatedSource = null;
      _error = false;
      _restoreOrLoad();
    }
  }

  void _restoreOrLoad() {
    // 会话缓存命中:同步恢复,重挂载零 IO 零解析
    final cached = _SvgContentCache.get(_cacheKey);
    if (cached != null) {
      if (cached.isError) {
        _error = true;
      } else {
        _si = cached.si;
        _animatedSource = cached.animatedSource;
      }
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final url = widget.url;
    final cacheKey = _cacheKey;
    try {
      final bytes =
          await BlobImageCache.fetch(BlobImageCache.contentBucket, url);
      if (!mounted || _cacheKey != cacheKey) return;

      // 大文件的解码+嗅探是全量字符串扫描,挪 isolate
      final (animated, rawContent) = bytes.length > _bigFileBytes
          ? await compute(_sniffSvgTask, bytes)
          : _sniffSvgTask(bytes);
      if (!mounted || _cacheKey != cacheKey) return;

      // 浏览器同款媒询求值:命中主题的暗/亮规则块展开,其余删除
      final content = SvgUtils.resolveColorSchemeMedia(
        rawContent,
        dark: _brightness == Brightness.dark,
      );

      if (animated) {
        // 动画 SVG 路由 full_svg_flutter(防注入剥离在 AnimatedSvgView 内做)
        final geo = AnimatedSvgView.rootGeometryOf(content);
        final memoW = geo.naturalW;
        final memoH = geo.naturalH ??
            (memoW != null ? memoW / geo.aspect : null);
        if (memoW != null && memoH != null) {
          MediaGeometryMemo.remember(url, memoW, memoH);
        }
        _SvgContentCache.put(cacheKey, _SvgEntry.animated(content));
        setState(() => _animatedSource = content);
        return;
      }

      final si = ScalableImage.fromSvgString(
        SvgUtils.sanitize(content),
        warnF: (_) {},
      );
      if (mounted && _cacheKey == cacheKey) {
        final vp = si.viewport;
        if (vp.width > 0 && vp.height > 0) {
          MediaGeometryMemo.remember(url, vp.width, vp.height);
        }
        _SvgContentCache.put(cacheKey, _SvgEntry.static_(si));
        setState(() => _si = si);
      }
    } catch (_) {
      if (mounted && _cacheKey == cacheKey) {
        _SvgContentCache.put(cacheKey, const _SvgEntry.error());
        setState(() => _error = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_animatedSource != null) {
      final view = AnimatedSvgView(
        svgSource: _animatedSource!,
        fit: widget.fit,
        alignment: widget.alignment,
        autoPlay: widget.autoPlayAnimated,
      );
      if (widget.width != null || widget.height != null) {
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: view,
        );
      }
      return view;
    }

    if (_si != null) {
      // 无显式尺寸时按 viewport 自然尺寸展示(对齐 DiscourseImage 原语义)
      return SizedBox(
        width: widget.width ?? _si!.viewport.width,
        height: widget.height ?? _si!.viewport.height,
        child: ScalableImageWidget(si: _si!, fit: widget.fit),
      );
    }

    if (_error) {
      if (widget.errorBuilder != null) return widget.errorBuilder!(context);
      return Icon(
        Symbols.broken_image_rounded,
        size: 24,
        color: Theme.of(context).colorScheme.outline,
      );
    }

    if (widget.placeholderBuilder != null) {
      return widget.placeholderBuilder!(context);
    }
    // 加载中:优先用尺寸备忘预留精确宽高比(同一张图第二次起加载前
    // 布局即恒定,零跳变);无备忘才退化到固定高占位。
    final memo = MediaGeometryMemo.peek(widget.url);
    if (memo != null && widget.width == null && widget.height == null) {
      return Align(
        alignment: widget.alignment,
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: memo.$1),
          child: AspectRatio(
            aspectRatio: memo.$1 / memo.$2,
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height ?? 100,
      child: const Center(
        child: LoadingSpinner(size: 20),
      ),
    );
  }
}

/// 光栅解码失败后的内容嗅探兜底。
///
/// 动态徽章类服务的 SVG 常无 `.svg` 扩展名(如 `/badge?u=...`),按 URL
/// 后缀路由不到 SVG 管线,会流进普通位图解码并失败;此件按**字节内容**
/// 二次判定:是 SVG 则转入 [DiscourseSvgView](静态/动画自动路由),
/// 否则显示调用方的破图占位。解码失败时字节已在磁盘缓存,嗅探是本地读。
class SvgSniffFallback extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 判定非 SVG 时的破图占位。
  final WidgetBuilder brokenBuilder;

  /// 嗅探中/转入 SVG 管线加载中的占位;不传用默认中性色块。
  final WidgetBuilder? placeholderBuilder;

  const SvgSniffFallback({
    super.key,
    required this.url,
    required this.brokenBuilder,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.placeholderBuilder,
  });

  @override
  State<SvgSniffFallback> createState() => _SvgSniffFallbackState();
}

class _SvgSniffFallbackState extends State<SvgSniffFallback> {

  /// url → 嗅探结论(会话级,同图反复失败不重复读盘)。
  static final Map<String, bool> _verdicts = <String, bool>{};

  bool? _isSvg;

  @override
  void initState() {
    super.initState();
    _isSvg = _verdicts[widget.url];
    if (_isSvg == null) _sniff();
  }

  @override
  void didUpdateWidget(covariant SvgSniffFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _isSvg = _verdicts[widget.url];
      if (_isSvg == null) _sniff();
    }
  }

  Future<void> _sniff() async {
    final url = widget.url;
    try {
      final bytes =
          await BlobImageCache.fetch(BlobImageCache.contentBucket, url);
      final verdict = SvgUtils.isSvgBytes(bytes);
      _verdicts[url] = verdict;
      if (mounted && widget.url == url) setState(() => _isSvg = verdict);
    } catch (_) {
      _verdicts[url] = false;
      if (mounted && widget.url == url) setState(() => _isSvg = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_isSvg) {
      case true:
        return DiscourseSvgView(
          url: widget.url,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          placeholderBuilder: widget.placeholderBuilder,
          errorBuilder: widget.brokenBuilder,
        );
      case false:
        return widget.brokenBuilder(context);
      case null:
        // 嗅探中(本地读,通常一两帧):中性占位,避免破图闪现
        if (widget.placeholderBuilder != null) {
          return widget.placeholderBuilder!(context);
        }
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
        );
    }
  }
}
