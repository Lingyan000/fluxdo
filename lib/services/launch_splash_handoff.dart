import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 原生启动屏与 Flutter 启动页的交接。
///
/// Android 13+ 登记过启动屏主题后，原生启动屏会播放 logo 描线动画（与
/// 启动页同源生成）。此时 Flutter 首帧直接画完整 logo，原生屏停留到描线
/// 播完再撤下；撤下前启动页的光晕、角标、退场都要等，否则会在原生屏
/// 底下悄悄播完。其余平台原生屏只有底色，由启动页从空白开始描线。
/// 系统偶尔仍会改用无图标的纯色启动屏：撤下前原生会通知改为从空白描线。
class LaunchSplashHandoff {
  LaunchSplashHandoff._();

  static const _channel = MethodChannel('com.github.lingyan000.fluxdo/splash');

  /// 原生屏撤下但未回报时的兜底等待（自启动页首帧起算）
  static const _fallback = Duration(milliseconds: 1500);

  /// 本次启动原生屏是否已播放 logo 描线
  static bool get nativeDrewLogo => nativeLogo.value;

  /// 原生屏是否画了 logo；撤下前发现实际没画时会改为 false
  static final ValueNotifier<bool> nativeLogo = ValueNotifier(false);

  /// 原生启动屏是否仍盖在 Flutter 之上
  static final ValueNotifier<bool> nativeSplashVisible = ValueNotifier(false);

  static Timer? _fallbackTimer;

  /// 在 runApp 之前调用：询问原生状态并接收撤下通知
  static Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>('state');
      nativeLogo.value = state?['nativeLogo'] == true;
      if (!nativeDrewLogo || state?['removed'] == true) return;
    } catch (e) {
      debugPrint('[LaunchSplashHandoff] 读取原生启动屏状态失败: $e');
      return;
    }
    nativeSplashVisible.value = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'restartStroke':
          // 启动页据此清空 logo，画完这一帧原生屏才撤下
          nativeLogo.value = false;
          await WidgetsBinding.instance.endOfFrame;
        case 'removed':
          _markRemoved();
          final trace = call.arguments;
          if (trace is Map) {
            AppLogger.info(
              '原生启动屏交接',
              tag: 'LaunchSplash',
              fields: trace.cast<String, dynamic>(),
            );
          }
      }
    });
  }

  /// 启动页首帧后调用：原生屏最迟在描线播完后撤下，回报丢失时兜底放行
  static void armFallback() {
    if (!nativeSplashVisible.value || _fallbackTimer != null) return;
    _fallbackTimer = Timer(_fallback, _markRemoved);
  }

  static void _markRemoved() {
    _fallbackTimer?.cancel();
    nativeSplashVisible.value = false;
  }

  /// 把应用内深浅色设置告知系统（Android 12+），下次冷启动的原生启动屏
  /// 据此选用浅色/深色资源，与启动页一致；否则原生屏只能跟随系统。
  static void syncNightMode(ThemeMode mode) {
    if (kIsWeb || !Platform.isAndroid) return;
    _channel.invokeMethod<void>('setNightMode', {'mode': mode.name}).catchError(
      (Object e) {
        debugPrint('[LaunchSplashHandoff] 同步深浅色设置失败: $e');
      },
    );
  }
}
