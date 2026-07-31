import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视频播放位置记忆(「看到一半退出,重进继续播」)。
///
/// 存储:SharedPreferences 单 key JSON,`{urlKey: {p, d, t}}`
/// (p=位置ms, d=总时长ms, t=最后写入epoch秒)。
///
/// - urlKey = sha1(url 去 query/fragment) 前 16 hex:签名 CDN 的 query
///   每次会话都变,path 才稳定;哈希兼顾长度与隐私。
/// - LRU 上限 [_maxEntries] 条,按 t 淘汰最旧;附带 [_maxAge] 保鲜期,
///   load 时顺手清理。
/// - 只记 [minDuration] 以上的视频;位置在片头 [headSkip] 内或距片尾
///   [tailSkip] 内时删除条目(几乎没看/看完了,下次从头)。
/// - 内存态即时更新,落盘 [_flushDelay] debounce 合并。
class PlaybackPositionStore {
  PlaybackPositionStore._();

  static final PlaybackPositionStore instance = PlaybackPositionStore._();

  static const String _prefsKey = 'media_playback_positions';
  static const int _maxEntries = 200;
  static const Duration _maxAge = Duration(days: 90);
  static const Duration _flushDelay = Duration(milliseconds: 300);

  /// 记忆门槛:短视频(表情包/动图类)从头播代价为零,不值得记。
  static const Duration minDuration = Duration(seconds: 60);

  /// 片头/片尾豁免区:落在其中视为「没看/看完」,删条目。
  static const Duration headSkip = Duration(seconds: 5);
  static const Duration tailSkip = Duration(seconds: 10);

  Map<String, _Entry>? _entries;
  SharedPreferences? _prefs;
  Timer? _flushTimer;
  Future<void>? _loading;

  /// 内存态与磁盘不一致时为 true。[flush] 据此短路:快速滚动中批量
  /// 销毁的暂停视频会各触发一次收尾 flush,无变更时必须是纯空操作。
  bool _dirty = false;

  /// 当前时间源,测试可注入。
  DateTime Function() now = DateTime.now;

  /// 读取 [url] 的续播位置;无记忆返回 null。
  ///
  /// 首次调用触发懒加载(载入时顺带清理过期条目)。
  Future<Duration?> restore(String url) async {
    await _ensureLoaded();
    final entry = _entries![_keyFor(url)];
    if (entry == null) return null;
    return Duration(milliseconds: entry.positionMs);
  }

  /// 写入 [url] 的播放进度。不满足记忆条件时转为删除条目。
  ///
  /// 内存态同步生效,落盘 debounce;高频调用(播放中节流写)安全。
  Future<void> save(String url, Duration position, Duration duration) async {
    await _ensureLoaded();
    final key = _keyFor(url);
    if (duration < minDuration ||
        position < headSkip ||
        position > duration - tailSkip) {
      if (_entries!.remove(key) != null) {
        _dirty = true;
        _scheduleFlush();
      }
      return;
    }
    final old = _entries![key];
    final entry = _Entry(
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      touchedAtSec: now().millisecondsSinceEpoch ~/ 1000,
    );
    // 位置没动(暂停态反复触发保存)不置脏,避免无谓写盘
    if (old != null && old.positionMs == entry.positionMs) return;
    _entries![key] = entry;
    _dirty = true;
    _evictIfNeeded();
    _scheduleFlush();
  }

  /// 删除 [url] 的记忆(用户显式从头播等场景)。
  Future<void> remove(String url) async {
    await _ensureLoaded();
    if (_entries!.remove(_keyFor(url)) != null) {
      _dirty = true;
      _scheduleFlush();
    }
  }

  /// 立即落盘(Session 收尾等不容 debounce 的时机)。无脏数据时空操作。
  Future<void> flush() async {
    if (!_dirty) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    final entries = _entries;
    if (entries == null) return;
    _dirty = false;
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(entries.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  static String _keyFor(String url) {
    final uri = Uri.tryParse(url);
    final canonical = uri == null
        ? url
        : uri.replace(query: '', fragment: '').toString();
    return sha1.convert(utf8.encode(canonical)).toString().substring(0, 16);
  }

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final entries = <String, _Entry>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final cutoff =
            now().millisecondsSinceEpoch ~/ 1000 - _maxAge.inSeconds;
        for (final MapEntry(:key, :value) in decoded.entries) {
          final entry = _Entry.fromJson(value as Map<String, dynamic>);
          if (entry.touchedAtSec >= cutoff) entries[key] = entry;
        }
      } catch (_) {
        // 损坏数据直接丢弃,位置记忆是尽力而为的增强
      }
    }
    _entries = entries;
  }

  void _evictIfNeeded() {
    final entries = _entries!;
    if (entries.length <= _maxEntries) return;
    final sorted = entries.entries.toList()
      ..sort((a, b) => a.value.touchedAtSec.compareTo(b.value.touchedAtSec));
    for (var i = 0; i < entries.length - _maxEntries; i++) {
      entries.remove(sorted[i].key);
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () => unawaited(flush()));
  }
}

class _Entry {
  const _Entry({
    required this.positionMs,
    required this.durationMs,
    required this.touchedAtSec,
  });

  final int positionMs;
  final int durationMs;
  final int touchedAtSec;

  factory _Entry.fromJson(Map<String, dynamic> json) => _Entry(
        positionMs: (json['p'] as num?)?.toInt() ?? 0,
        durationMs: (json['d'] as num?)?.toInt() ?? 0,
        touchedAtSec: (json['t'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() =>
      {'p': positionMs, 'd': durationMs, 't': touchedAtSec};
}
