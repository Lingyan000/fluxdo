import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_provider.dart';

/// 渲染后端回退开关（仅 Android 生效）。
///
/// 开启后，下次冷启动由 `MainActivity.provideFlutterEngine` 以
/// `--impeller-backend=opengles` 创建引擎，让 Impeller 走 OpenGL ES 后端，
/// 绕开部分 Mali Vulkan 驱动在纹理/表面销毁时的 SIGABRT 竞态
/// （mali-event-hand 线程 destroyed mutex，栈全在 libGLES_mali.so）。
///
/// native 侧直接读 shared_preferences 的同一份文件
/// （"FlutterSharedPreferences"，键带 flutter. 前缀），不经过 Dart，
/// 因此重启应用（进程重建）即可生效。
class RenderBackendPrefs {
  /// native 侧读写的 SharedPreferences 文件名与 Dart 键名，必须与
  /// MainActivity 中的常量保持一致。
  static const nativePrefsFile = 'FlutterSharedPreferences';
  static const dartPrefKey = 'renderer_gles';
  static const nativePrefKey = 'flutter.$dartPrefKey';
}

final renderGlesBackendProvider =
    NotifierProvider<RenderGlesBackendNotifier, bool>(
      RenderGlesBackendNotifier.new,
    );

class RenderGlesBackendNotifier extends Notifier<bool> {
  bool get _supported => !kIsWeb && Platform.isAndroid;

  @override
  bool build() {
    if (!_supported) return false;
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(RenderBackendPrefs.dartPrefKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    if (!_supported) return;
    state = enabled;
    await ref
        .read(sharedPreferencesProvider)
        .setBool(RenderBackendPrefs.dartPrefKey, enabled);
  }
}
