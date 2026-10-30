import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 渲染后端兼容模式的原生桥接（仅 Android）。
///
/// 承担两件事：
/// 1. **崩溃自动识别** —— 原生侧扫描上次进程退出记录，判断是否疑似
///    Mali/Vulkan 渲染崩溃。判定分 A/B 两级（详见 RenderCrashDetector.kt）：
///    tombstone 直接命中 Mali 关键字则崩 1 次即建议；拿不到 tombstone 时
///    退化为「前台 native 崩溃 + Mali GPU」累计 2 次才建议。
/// 2. **启动快照同步** —— 偏好写入后同步一份到只含单个 boolean 的小文件，
///    让下次冷启动的 `provideFlutterEngine` 不必解析整个偏好文件。
///
/// 该能力**不依赖 Crashlytics 开关**：纯本地判断、零网络请求，所有用户都
/// 应当被提醒。
class RenderBackendService {
  const RenderBackendService._();

  static const MethodChannel _channel = MethodChannel(
    'com.github.lingyan000.fluxdo/render_backend',
  );

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 是否应当弹窗建议开启兼容模式。
  ///
  /// 取走即清除，保证同一次检测结果只弹一次窗。
  static Future<bool> shouldSuggestCompatMode() async {
    if (!_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'checkRenderCrashSuggestion',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('渲染崩溃检测失败: $e');
      return false;
    }
  }

  /// 历史上是否检测到过渲染崩溃 —— 设置页据此常驻显示「建议开启」。
  ///
  /// 与 [shouldSuggestCompatMode] 不同，这个标记不会被消费：用户点了
  /// 「暂不开启」后不再弹窗，但设置项上的建议保留，方便之后想起来。
  static Future<bool> hasDetectedRenderCrash() async {
    if (!_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasDetectedRenderCrash',
      );
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 记录用户明确拒绝，之后不再自动弹窗。
  static Future<void> dismissSuggestion() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('dismissRenderCrashSuggestion');
    } catch (e) {
      debugPrint('记录用户拒绝失败: $e');
    }
  }

  /// 把偏好同步到原生启动快照。
  ///
  /// 必须在偏好落盘后调用。同步失败不影响功能正确性 —— 原生侧读不到快照时
  /// 会回退去解析 shared_preferences 的主文件。
  static Future<void> syncFlag(bool enabled) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('syncRenderGlesFlag', {
        'enabled': enabled,
      });
    } catch (e) {
      debugPrint('同步渲染快照失败: $e');
    }
  }
}
