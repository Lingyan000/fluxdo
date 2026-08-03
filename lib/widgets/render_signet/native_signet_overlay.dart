import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'render_signet_codec.dart';
import 'render_signet_layer.dart' show buildSignetTiles;

/// 窗口级原生印记层的 Dart 侧通道(macOS / Windows)。
///
/// 编码单一真相仍在 Dart:[buildSignetTiles] 产出 modulate/plus 双笔
/// 图块后,以未编码 RGBA(预乘)字节下发,原生侧只负责「平铺 + 混合」
/// (multiply ≙ modulate、linearDodge ≙ plus,先乘后加),不含任何
/// codec 逻辑。后端实现:macos Runner 的 RenderSignetHandler.swift
/// (CALayer compositingFilter)、windows/runner/render_signet_handler.cpp
/// (Windows.UI.Composition BackdropBrush + D2D Blend 效果链)。
///
/// 下沉动机分平台:
/// - macOS:Flutter 层的全屏绘制会被引擎统计进平台视图上方的
///   backing store paint region,`FlutterMutatorView.hitTest` 对该区域
///   直接返 nil——WKWebView 整块收不到鼠标事件(macOS 无手势转发
///   兜底)。原生兄弟视图不参与该统计。
/// - Windows:Skia+ANGLE 无 partial repaint,内联两笔全屏 dst-read
///   混合每帧全额支付,核显+高刷实测卡顿;合成器端做增量接近零。
/// 共同副产品:印记连 WebView 自身的像素也能盖到。
///
/// iOS 曾短暂接入 CALayer 后端,已下线回退内联(用户白屏反馈,根因
/// 候选与回退理由见 [RenderSignetLayer] 类注释)。
class NativeSignetOverlay {
  NativeSignetOverlay._();

  static final NativeSignetOverlay instance = NativeSignetOverlay._();

  static const _channel = MethodChannel('com.fluxdo/render_signet');

  int? _wantId;
  double _wantDpr = 1.0;
  int? _sentId;
  double? _sentDpr;
  bool _pumping = false;

  /// 声明期望状态(标识值 + 当前 DPR),内部合并去重后异步同步到原生。
  /// [id] 为 null 表示移除印记层(登出/无会话)。
  void sync({required int? id, required double dpr}) {
    _wantId = id;
    _wantDpr = dpr;
    _pump();
  }

  bool get _dirty =>
      _sentId != _wantId || (_wantId != null && _sentDpr != _wantDpr);

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_dirty) {
        final id = _wantId;
        final dpr = _wantDpr;
        if (id == null) {
          await _channel.invokeMethod<bool>('remove');
        } else {
          await _channel.invokeMethod<bool>('install', await _payload(id, dpr));
        }
        _sentId = id;
        _sentDpr = dpr;
      }
    } catch (e) {
      // 通道失败(如原生侧未注册)不重试:留给下一次 sync 触发。
      debugPrint('[NativeSignetOverlay] 同步失败: $e');
    } finally {
      _pumping = false;
    }
  }

  Future<Map<String, Object>> _payload(int id, double dpr) async {
    // opaquePlusPen:CA linearDodge 对半透明源会做 α 合成稀释,
    // 需要 α=255 的点才能拿到干净的 B+δ,见 buildSignetTiles 注释
    final (mod, plus) = buildSignetTiles(id, dpr, opaquePlusPen: true);
    try {
      final modBytes = await mod.toByteData(format: ui.ImageByteFormat.rawRgba);
      final plusBytes = await plus.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (modBytes == null || plusBytes == null) {
        throw StateError('印记图块像素回读失败');
      }
      return {
        // rawRgba 为预乘 alpha,原生侧按 premultipliedLast 建 CGImage
        'modTile': modBytes.buffer.asUint8List(
          modBytes.offsetInBytes,
          modBytes.lengthInBytes,
        ),
        'plusTile': plusBytes.buffer.asUint8List(
          plusBytes.offsetInBytes,
          plusBytes.lengthInBytes,
        ),
        'tilePx': mod.width,
        'period': kSignetBlockPeriod,
      };
    } finally {
      mod.dispose();
      plus.dispose();
    }
  }
}
