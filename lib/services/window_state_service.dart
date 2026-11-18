import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/legacy.dart';

/// 桌面窗口状态持久化服务
///
/// 保存/恢复窗口的大小、位置和最大化状态。
/// 通过 [startListening] 监听窗口变化并自动保存（防抖 500ms）。
class WindowStateService with WindowListener {
  WindowStateService._();
  static final WindowStateService instance = WindowStateService._();

  static const _kLegacyX = 'window_x';
  static const _kLegacyY = 'window_y';
  static const _kLegacyW = 'window_w';
  static const _kLegacyH = 'window_h';
  static const _kLegacyMaximized = 'window_maximized';
  static const _kStateFileName = 'window_state.json';
  static const _kMinVisibleExtent = 64.0;
  static const _kWindowsMinimizedPlaceholder = -30000.0;

  SharedPreferences? _prefs;
  Timer? _saveTimer;
  File? _stateFile;
  bool? _isMaximizedCache;
  bool _isListening = false;

  Future<void> attach(SharedPreferences prefs) async {
    _prefs = prefs;
    _isMaximizedCache = await windowManager.isMaximized();
  }

  /// 恢复上次保存的窗口状态并显示窗口
  Future<void> restore(SharedPreferences prefs) async {
    await attach(prefs);

    final state = await _loadState();
    final bounds = await _getRestorableBounds(state?.bounds);
    _isMaximizedCache = state?.isMaximized ?? false;

    if (bounds != null) {
      await windowManager.setBounds(bounds);
    }
    if (state?.isMaximized == true) {
      await windowManager.maximize();
    }
    await windowManager.show();
  }

  /// 开始监听窗口变化
  void startListening() {
    if (_isListening) return;
    _isListening = true;
    windowManager.addListener(this);
  }

  /// 停止监听并清理资源
  void stopListening() {
    _saveTimer?.cancel();
    _isListening = false;
    windowManager.removeListener(this);
  }

  /// 立即保存当前窗口状态
  Future<void> save() async {
    try {
      final file = await _getStateFile();
      final isMaximized =
          _isMaximizedCache ?? await windowManager.isMaximized();
      final isMinimized = await windowManager.isMinimized();
      Rect? bounds;
      _isMaximizedCache = isMaximized;

      // 最大化/最小化时不覆盖尺寸和位置，避免持久化不可恢复的窗口坐标
      if (!isMaximized && !isMinimized) {
        final currentBounds = await windowManager.getBounds();
        if (isBoundsRestorable(currentBounds, const <Rect>[])) {
          bounds = currentBounds;
        } else {
          debugPrint('[WindowStateService] 忽略无效窗口位置: $currentBounds');
        }
      }

      final state = _StoredWindowState(
        isMaximized: isMaximized,
        bounds: bounds,
      );

      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state.toJson()));
    } catch (e) {
      debugPrint('[WindowStateService] 保存窗口状态失败: $e');
    }
  }

  /// 防抖保存
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), save);
  }

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() {
    _isMaximizedCache = true;
    _scheduleSave();
  }

  @override
  void onWindowUnmaximize() {
    _isMaximizedCache = false;
    _scheduleSave();
  }

  @override
  void onWindowClose() async {
    _saveTimer?.cancel();
    // 先隐藏窗口，让用户感知上立即关闭，再执行耗时的保存和清理
    await windowManager.hide();
    try {
      await save();
    } finally {
      if (!Platform.isMacOS) {
        // macOS: 隐藏即可，Dock 图标可以重新唤起；其他平台需要销毁
        await windowManager.destroy();
      }
    }
  }

  Future<_StoredWindowState?> _loadState() async {
    final file = await _getStateFile();
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            return _StoredWindowState.fromJson(decoded);
          }
          if (decoded is Map) {
            return _StoredWindowState.fromJson(decoded.cast<String, dynamic>());
          }
        }
      } catch (_) {}
    }

    final prefs = _prefs;
    if (prefs == null) return null;

    final legacyState = _loadLegacyState(prefs);
    if (legacyState != null) {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(legacyState.toJson()));
    }
    return legacyState;
  }

  _StoredWindowState? _loadLegacyState(SharedPreferences prefs) {
    final isMaximized = prefs.getBool(_kLegacyMaximized) ?? false;
    final w = prefs.getDouble(_kLegacyW);
    final h = prefs.getDouble(_kLegacyH);
    final x = prefs.getDouble(_kLegacyX);
    final y = prefs.getDouble(_kLegacyY);

    Rect? bounds;
    if (w != null && h != null && x != null && y != null) {
      bounds = Rect.fromLTWH(x, y, w, h);
    }

    if (!isMaximized && bounds == null) {
      return null;
    }

    return _StoredWindowState(isMaximized: isMaximized, bounds: bounds);
  }

  Future<Rect?> _getRestorableBounds(Rect? bounds) async {
    if (bounds == null) return null;

    if (!isBoundsRestorable(bounds, const <Rect>[])) {
      debugPrint('[WindowStateService] 忽略无效窗口位置: $bounds');
      return null;
    }

    try {
      final visibleAreas = await _loadVisibleDisplayAreas();
      if (!isBoundsRestorable(bounds, visibleAreas)) {
        debugPrint('[WindowStateService] 忽略屏幕外窗口位置: $bounds');
        return null;
      }
    } catch (e) {
      debugPrint('[WindowStateService] 校验屏幕位置失败: $e');
    }

    return bounds;
  }

  Future<List<Rect>> _loadVisibleDisplayAreas() async {
    final displays = await screenRetriever.getAllDisplays();
    return displays
        .map(_visibleAreaOf)
        .where(_isFinitePositiveRect)
        .toList(growable: false);
  }

  static Rect _visibleAreaOf(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return position & size;
  }

  @visibleForTesting
  static bool isBoundsRestorable(Rect bounds, Iterable<Rect> visibleAreas) {
    if (!_isFinitePositiveRect(bounds)) return false;
    if (_looksLikeWindowsMinimizedPlaceholder(bounds)) return false;

    final areas = visibleAreas
        .where(_isFinitePositiveRect)
        .toList(growable: false);
    if (areas.isEmpty) return true;

    for (final area in areas) {
      if (!area.overlaps(bounds)) continue;

      final overlap = area.intersect(bounds);
      final minVisibleWidth = math.min(bounds.width, _kMinVisibleExtent);
      final minVisibleHeight = math.min(bounds.height, _kMinVisibleExtent);
      if (overlap.width >= minVisibleWidth &&
          overlap.height >= minVisibleHeight) {
        return true;
      }
    }

    return false;
  }

  static bool _isFinitePositiveRect(Rect rect) {
    return rect.isFinite && rect.width > 0 && rect.height > 0;
  }

  static bool _looksLikeWindowsMinimizedPlaceholder(Rect rect) {
    return rect.left <= _kWindowsMinimizedPlaceholder &&
        rect.top <= _kWindowsMinimizedPlaceholder &&
        rect.width <= 300 &&
        rect.height <= 300;
  }

  Future<File> _getStateFile() async {
    final cached = _stateFile;
    if (cached != null) return cached;

    final directory = await getApplicationSupportDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}$_kStateFileName',
    );
    _stateFile = file;
    return file;
  }
}

class _StoredWindowState {
  const _StoredWindowState({required this.isMaximized, required this.bounds});

  final bool isMaximized;
  final Rect? bounds;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'isMaximized': isMaximized,
      if (bounds != null) 'x': bounds!.left,
      if (bounds != null) 'y': bounds!.top,
      if (bounds != null) 'width': bounds!.width,
      if (bounds != null) 'height': bounds!.height,
    };
  }

  static _StoredWindowState? fromJson(Map<String, dynamic> json) {
    final isMaximized = json['isMaximized'];
    if (isMaximized is! bool) {
      return null;
    }

    final x = (json['x'] as num?)?.toDouble();
    final y = (json['y'] as num?)?.toDouble();
    final width = (json['width'] as num?)?.toDouble();
    final height = (json['height'] as num?)?.toDouble();

    Rect? bounds;
    if (x != null && y != null && width != null && height != null) {
      bounds = Rect.fromLTWH(x, y, width, height);
    }

    if (!isMaximized && bounds == null) {
      return null;
    }

    return _StoredWindowState(isMaximized: isMaximized, bounds: bounds);
  }
}
