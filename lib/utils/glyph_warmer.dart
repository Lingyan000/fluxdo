import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/local_notification_service.dart' show navigatorKey;
import 'frame_jank_monitor.dart';
import 'scroll_busy_signal.dart';

/// CJK 字形图集预热器:把"新字形进屏时的图集扩容/搬家"成本从滚动帧
/// 驱赶到无交互的帧里去付。
///
/// ## 为什么(病灶)
///
/// Impeller 的字形图集是惰性填充的:文字排版在 UI 线程早已完成,但字形
/// 位图要等**首次被画上屏那一帧**才在 raster 线程栅格化进图集;图集装满
/// 时分配更大纹理并把旧图集整体 blit 搬家(成本随积累递增),打到 GPU
/// 纹理上限后 GC 重建。中文几千常用字 × 4 个亚像素变体 × 多字号,滚动
/// 长文字话题必然反复触发 —— 生产日志里 44→96→189ms 的孤立 raster
/// 大帧即此(资源清单已排除图片,幅度递增是搬家成本∝积累量的指纹)。
///
/// ## 怎么修(本类)
///
/// 话题数据解析完成后,把**实际内容**里的去重 CJK 字符(动态派生,无
/// 静态字表)用真实正文样式画进一个近零 alpha 的全局覆盖层 —— 字形
/// 因此提前进入图集,扩容/搬家全部发生在预热帧里;等用户滚到时全是
/// 命中,滚动帧不再有图集增量。
///
/// 调度上不赌"预测的空闲":
/// - 分小块(每帧 [_chunkSize] 字),指下即停(全局 pointer 路由),
///   滚动中让路(ScrollBusySignal);
/// - 没预热完就开滚 = 剩余字形回退惰性填充,**最坏情况等于现状**,
///   单调不劣化;
/// - 跨话题按会话去重,中文字频 Zipf 分布,几个话题后新字率断崖,
///   预热趋近空操作。
///
/// 每个字画 4 遍(X 方向各平移 1/4 设备像素):Impeller 按 4 个亚像素
/// 桶分别入册(text_frame.cc 的 ComputeFractionalPosition),只热一桶
/// 图集撑不到工作集平台期,滚动期照样扩容。
///
/// 字号/字体/dpr 任一变化即换代(epoch):旧字形条目作废,会话集清空
/// 重热(仍只花无交互帧)。
class GlyphWarmer {
  GlyphWarmer._();

  static const String prefKey = 'pref_glyph_warm';

  /// 诊断开关(性能诊断页可关,便于线上 A/B 验证收益)
  static bool enabled = true;

  /// 每帧预热的字符数。64 字 × 4 亚像素变体 = 256 个字形实例/帧,
  /// 单帧 raster 增量约 10~25ms —— 只发生在无交互帧,不可感知;
  /// 更大的块会把"指下即弃"的在途敞口撑大。
  static const int _chunkSize = 64;

  /// 队列上限(防御病态输入;超出部分等下次 feed 再来)
  static const int _queueCap = 20000;

  static final Set<int> _warmed = <int>{};
  static final Set<int> _pending = <int>{};
  static final List<int> _queue = <int>[];

  static String _epoch = '';
  static TextStyle? _style;
  static double _dpr = 1.0;

  static OverlayEntry? _entry;
  static _WarmOverlayState? _overlay;
  static Timer? _retryTimer;
  static bool _pointerActive = false;
  static bool _pointerRouteAdded = false;
  static bool _pumpScheduled = false;

  /// 喂入一段实际内容文本(cooked HTML 原文即可:ASCII 标签被字符
  /// 范围过滤天然跳过)。style 必须是正文实际渲染样式(字号含
  /// contentFontScale),否则热错刻度全部落空。
  static void feed({
    required String text,
    required TextStyle style,
    required double devicePixelRatio,
  }) {
    if (!enabled || text.isEmpty) return;

    final epoch =
        '${style.fontSize}|${style.fontWeight}|${style.fontFamily}|$devicePixelRatio';
    if (epoch != _epoch) {
      _epoch = epoch;
      _style = style;
      _dpr = devicePixelRatio;
      _warmed.clear();
      _pending.clear();
      _queue.clear();
    }

    var added = false;
    for (final rune in text.runes) {
      if (!_isWarmable(rune)) continue;
      if (_warmed.contains(rune) || _pending.contains(rune)) continue;
      if (_queue.length >= _queueCap) break;
      _pending.add(rune);
      _queue.add(rune);
      added = true;
    }
    if (added) _schedulePump();
  }

  /// CJK 及全角标点范围。ASCII/拉丁不热(条目小且首屏即热),emoji
  /// 走彩色图集与独立管线,代理对(扩展 B 等生僻字)罕见,回退惰性。
  static bool _isWarmable(int rune) {
    return (rune >= 0x2E80 && rune <= 0x9FFF) || // 部首/假名/CJK 标点/统一表意
        (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容表意
        (rune >= 0xFF00 && rune <= 0xFFEF); // 全角形式
  }

  static void _ensurePointerRoute() {
    if (_pointerRouteAdded) return;
    _pointerRouteAdded = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (event is PointerDownEvent) {
        _pointerActive = true;
      } else if (event is PointerUpEvent || event is PointerCancelEvent) {
        _pointerActive = false;
      }
    });
  }

  static void _schedulePump() {
    if (_pumpScheduled || _queue.isEmpty) return;
    _pumpScheduled = true;
    // 让开当前帧:feed 发生在 build/数据回调里,本帧已经有正事
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pumpScheduled = false;
      _pump();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  static void _pump() {
    if (!enabled || _queue.isEmpty) return;
    _ensurePointerRoute();

    // 交互让路:手指在屏上 / 滚动衰减尾巴里,一个字都不动。
    // 在途敞口只有"已提交给当前帧的那一块"。
    if (_pointerActive || ScrollBusySignal.isBusy) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(milliseconds: 400), _pump);
      return;
    }

    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 1), _pump);
      return;
    }
    if (_entry == null) {
      final entry = OverlayEntry(builder: (_) => const _WarmOverlay());
      _entry = entry;
      overlay.insert(entry);
      // 等 overlay 首帧挂载完成再走正常泵循环
      _schedulePump();
      return;
    }

    final host = _overlay;
    if (host == null || !host.mounted) return;

    final take = _queue.length < _chunkSize ? _queue.length : _chunkSize;
    final chunk = _queue.sublist(0, take);
    _queue.removeRange(0, take);
    host._showChunk(String.fromCharCodes(chunk), _style!, _dpr);

    // 本帧 raster 完成即入册;下一轮泵推进到帧后,保证一帧一块
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final rune in chunk) {
        _pending.remove(rune);
        _warmed.add(rune);
      }
      if (_queue.isNotEmpty) {
        _pump();
      } else {
        host._showChunk('', _style!, _dpr); // 清画布,覆盖层归零成本
      }
    });
  }
}

/// 全局预热覆盖层:全屏、不参与命中测试、RepaintBoundary 隔离,
/// 只在有块可画时非空。文字 alpha = 1/255 —— 不可感知,但不会被
/// 引擎按"全透明"剔除(alpha 0 会被剔,字形就进不了图集)。
class _WarmOverlay extends StatefulWidget {
  const _WarmOverlay();

  @override
  State<_WarmOverlay> createState() => _WarmOverlayState();
}

class _WarmOverlayState extends State<_WarmOverlay> {
  TextPainter? _painter;
  double _dpr = 1.0;
  int _chunkChars = 0;

  @override
  void initState() {
    super.initState();
    GlyphWarmer._overlay = this;
  }

  @override
  void dispose() {
    if (identical(GlyphWarmer._overlay, this)) GlyphWarmer._overlay = null;
    _painter?.dispose();
    super.dispose();
  }

  void _showChunk(String chunk, TextStyle style, double dpr) {
    if (!mounted) return;
    _painter?.dispose();
    if (chunk.isEmpty) {
      _painter = null;
      _chunkChars = 0;
    } else {
      _painter = TextPainter(
        text: TextSpan(
          text: chunk,
          // alpha 1/255:分支见类注释。颜色不影响入册 —— alpha 图集
          // 存的是覆盖率掩码,颜色在采样时才应用
          style: style.copyWith(color: const Color(0x01000000)),
        ),
        textDirection: TextDirection.ltr,
      );
      _chunkChars = chunk.length;
      _dpr = dpr;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_painter != null) {
      FrameJankMonitor.noteBuild('warm$_chunkChars');
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _painter == null
              ? null
              : _WarmPainter(painter: _painter!, dpr: _dpr),
        ),
      ),
    );
  }
}

class _WarmPainter extends CustomPainter {
  _WarmPainter({required this.painter, required this.dpr});

  final TextPainter painter;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    // 留边距,保证字形都在覆盖层裁剪范围内(出界的绘制会被剔除,
    // 字形就白热了)
    painter.layout(maxWidth: size.width - 16);
    // 4 个亚像素桶:X 各平移 1/4 设备像素(逻辑坐标 = 0.25/dpr)。
    // 命中已有桶的实例由引擎 CollectNewGlyphs 去重,近乎免费
    for (var k = 0; k < 4; k++) {
      painter.paint(canvas, Offset(8 + k * 0.25 / dpr, 8));
    }
  }

  @override
  bool shouldRepaint(_WarmPainter oldDelegate) =>
      !identical(oldDelegate.painter, painter) || oldDelegate.dpr != dpr;
}
