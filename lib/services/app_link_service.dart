import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 应用链接解析结果
class AppLinkInfo {
  /// 是否能解析到目标应用
  final bool canResolve;

  /// 应用名称（仅 Android 可获取）
  final String? appName;

  /// 包名（仅 Android）
  final String? packageName;

  /// 应用图标 PNG 字节（仅 Android 可获取）
  final Uint8List? appIcon;

  const AppLinkInfo({
    required this.canResolve,
    this.appName,
    this.packageName,
    this.appIcon,
  });

  @override
  String toString() =>
      'AppLinkInfo(canResolve=$canResolve, appName=$appName, '
      'packageName=$packageName, iconBytes=${appIcon?.length ?? 0})';
}

/// 应用链接服务
///
/// 通过原生 MethodChannel 解析和启动应用链接。
/// - Android：使用 PackageManager 获取目标应用名称和图标
/// - iOS：使用 UIApplication.open 启动链接（无法获取图标）
/// - 桌面平台：无原生实现，回退到 url_launcher
class AppLinkService {
  static const _channel = MethodChannel('com.github.lingyan000.fluxdo/browser');

  static bool get supportsDefaultLinkSettings =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 打开本应用的系统「默认打开链接」设置，不修改用户的关联选择。
  static Future<bool> openDefaultLinkSettings() async {
    if (!supportsDefaultLinkSettings) return false;
    try {
      return await _channel.invokeMethod<bool>('openDefaultLinkSettings') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 解析应用链接，获取目标应用信息
  static Future<AppLinkInfo> resolveAppLink(String url) async {
    debugPrint('[AppLink] resolveAppLink: $url');
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'resolveAppLink',
        {'url': url},
      );
      debugPrint('[AppLink] native result: $result');
      if (result != null) {
        final info = AppLinkInfo(
          canResolve: result['canResolve'] as bool? ?? false,
          appName: result['appName'] as String?,
          packageName: result['packageName'] as String?,
          appIcon: result['appIcon'] as Uint8List?,
        );
        debugPrint('[AppLink] parsed: $info');
        return info;
      }
    } catch (e) {
      debugPrint('[AppLink] resolveAppLink error: $e');
    }
    return const AppLinkInfo(canResolve: false);
  }

  /// 启动应用链接
  ///
  /// 优先通过原生 MethodChannel 启动（Android/iOS），
  /// 失败时回退到 url_launcher（桌面平台兜底）。
  static Future<bool> launchAppLink(String url) async {
    // 1. 尝试原生 MethodChannel
    try {
      final result = await _channel.invokeMethod<bool>('launchAppLink', {
        'url': url,
      });
      if (result == true) return true;
    } catch (_) {
      // 原生 channel 不可用（桌面平台）
    }

    // 2. 回退到 url_launcher
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
