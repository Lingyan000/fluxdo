import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:rfw/rfw.dart';

import 'metaverse_plugin_prelude.dart';
import 'metaverse_script_engine.dart';

/// 宿主向插件脚本提供的能力。所有权限判断都在实现里做。
abstract class MetaversePluginBridge {
  /// 处理脚本发起的调用；失败抛 [MetaversePluginCallException]。
  Future<Object?> call(String method, Map<String, Object?> params);

  void log(String level, String message);
}

/// 调用被拒绝或失败，[message] 会原样交给插件脚本。
class MetaversePluginCallException implements Exception {
  const MetaversePluginCallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 插件的一块界面：元宇宙页里的卡片，或一个独立页面。
class MetaversePluginSurface {
  MetaversePluginSurface._(this.id, this.kind, this.page, this.params);

  final String id;

  /// `card` 或 `page`。
  final String kind;
  final String? page;
  final Map<String, Object?> params;

  /// 脚本经 `ctx.setData` 写入、界面经 `data.xxx` 读取的数据。
  final DynamicContent data = DynamicContent();

  /// 承载该界面的 widget 上下文，供弹窗、跳转使用；界面卸载后为 null。
  BuildContext? context;
  bool _foreground = true;
  bool _appBackgrounded = false;
  bool get foreground => _foreground;

  Map<String, Object?> get _info => {
    'surface': id,
    'kind': kind,
    'page': page,
    'params': params,
  };
}

/// 一个插件的脚本运行时：负责脚本引擎与宿主之间的消息协议。
///
/// 这一层不做权限判断（那是 [MetaversePluginBridge] 的事），只保证协议健壮：
/// 脚本发来的任何消息都当作不可信输入校验，数量也设上限。
class MetaversePluginRuntime {
  MetaversePluginRuntime._(this._engine, this._bridge, this._onFatal) {
    _engine
      ..onMessage = _onMessage
      ..onFatal = _handleFatal;
  }

  static const _maxPendingCalls = 32;
  static const _maxTimers = 64;
  static const _maxTimerDelay = Duration(minutes: 10);
  static const _maxSurfaces = 16;
  static const _maxDataNodes = 20000;

  /// 启动引擎并执行插件脚本。脚本顶层抛错时启动失败。
  static Future<MetaversePluginRuntime> start({
    required MetaverseScriptEngineFactory engineFactory,
    required String script,
    required MetaversePluginBridge bridge,
    void Function(String reason)? onFatal,
  }) async {
    final engine = await engineFactory();
    final runtime = MetaversePluginRuntime._(engine, bridge, onFatal);
    try {
      await engine.evaluate(metaversePluginPrelude, name: 'fluxdo-prelude.js');
      await engine.evaluate(script, name: 'main.js');
    } catch (_) {
      runtime.dispose();
      rethrow;
    }
    return runtime;
  }

  final MetaverseScriptEngine _engine;
  final MetaversePluginBridge _bridge;
  final void Function(String reason)? _onFatal;

  final _surfaces = <String, MetaversePluginSurface>{};
  final _timers = <int, Timer>{};
  int _surfaceSeq = 0;
  int _pendingCalls = 0;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  Iterable<MetaversePluginSurface> get surfaces => _surfaces.values;
  bool owns(MetaversePluginSurface surface) =>
      identical(_surfaces[surface.id], surface);

  void setForeground(
    MetaversePluginSurface surface,
    bool foreground, {
    bool appForeground = true,
  }) {
    if (!owns(surface)) return;
    // 被上层路由遮住时也记录应用切后台，返回该页面后再通知恢复原因。
    surface._appBackgrounded |= !appForeground;
    if (surface._foreground == foreground) return;
    surface._foreground = foreground;
    if (surface.kind == 'page') {
      dispatch(surface, foreground ? 'page.resume' : 'page.hide', {
        'reason': surface._appBackgrounded ? 'app' : 'route',
      });
    }
    if (foreground) surface._appBackgrounded = false;
  }

  /// 打开一块界面并通知脚本（`card.load` / `page.open`）。
  MetaversePluginSurface openSurface({
    required String kind,
    String? page,
    Map<String, Object?> params = const {},
  }) {
    if (_surfaces.length >= _maxSurfaces) {
      throw StateError('插件同时打开的界面过多');
    }
    final surface = MetaversePluginSurface._(
      's${++_surfaceSeq}',
      kind,
      page,
      params,
    );
    _surfaces[surface.id] = surface;
    dispatch(surface, kind == 'card' ? 'card.load' : 'page.open', const {});
    return surface;
  }

  void closeSurface(MetaversePluginSurface surface) {
    if (!identical(_surfaces[surface.id], surface)) return;
    if (_surfaces.remove(surface.id) == null) return;
    surface.context = null;
    _dispatchRaw(surface, 'surface.close', const {});
  }

  /// 把界面事件交给脚本里 `fluxdo.on(name, ...)` 注册的处理器。
  void dispatch(
    MetaversePluginSurface surface,
    String name,
    Map<String, Object?> args,
  ) {
    if (!owns(surface)) return;
    _dispatchRaw(surface, name, args);
  }

  void _dispatchRaw(
    MetaversePluginSurface surface,
    String name,
    Map<String, Object?> args,
  ) {
    _run(
      '__fluxdoMetaverse.dispatch(${jsonEncode(name)}, '
      '${_literal(surface._info)}, ${_literal(args)})',
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final surface in _surfaces.values) {
      surface.context = null;
    }
    _surfaces.clear();
    _engine.dispose();
  }

  void _handleFatal(String reason) {
    if (_disposed) return;
    dispose();
    _onFatal?.call(reason);
  }

  /// 把一个值编码成 JS 字符串字面量，内容是它的 JSON。
  ///
  /// 界面事件的参数来自 rfw，理论上只有 JSON 值；万一混进别的对象就编码成
  /// null，不能让手势回调因此抛错。
  static String _literal(Object? value) =>
      jsonEncode(jsonEncode(value, toEncodable: (_) => null));

  void _run(String code) {
    if (_disposed) return;
    unawaited(
      _engine.evaluate(code, name: 'fluxdo-host.js').catchError((Object error) {
        if (!_disposed) _bridge.log('error', error.toString());
      }),
    );
  }

  void _onMessage(Object? message) {
    if (_disposed || message is! Map) return;
    switch (message['t']) {
      case 'call':
        _handleCall(message);
      case 'data':
        _handleData(message);
      case 'timer':
        _handleTimer(message);
      case 'log':
        _bridge.log(_text(message['level'], 16), _text(message['message']));
      case 'error':
        _bridge.log(
          'error',
          '[${_text(message['where'], 64)}] ${_text(message['message'])}'
              '\n${_text(message['stack'])}',
        );
    }
  }

  static String _text(Object? value, [int max = 4000]) {
    final text = value is String ? value : '$value';
    return text.length > max ? '${text.substring(0, max)}…' : text;
  }

  Future<void> _handleCall(Map<dynamic, dynamic> message) async {
    final id = message['id'];
    final method = message['m'];
    if (id is! int || method is! String) return;
    if (_pendingCalls >= _maxPendingCalls) {
      return _settle(id, false, '同时进行的调用过多');
    }
    final rawParams = message['p'];
    final params = rawParams is Map
        ? rawParams.cast<String, Object?>()
        : const <String, Object?>{};
    _pendingCalls++;
    try {
      _settle(id, true, await _bridge.call(method, params));
    } on MetaversePluginCallException catch (error) {
      _settle(id, false, error.message);
    } catch (error, stack) {
      // 宿主内部错误不带细节地交还，避免向插件泄露路径、堆栈等信息。
      debugPrint('[Metaverse] $method 处理失败: $error\n$stack');
      _settle(id, false, '宿主处理失败');
    } finally {
      _pendingCalls--;
    }
  }

  void _settle(int id, bool ok, Object? value) {
    _run('__fluxdoMetaverse.settle($id, $ok, ${_literal(value)})');
  }

  void _handleData(Map<dynamic, dynamic> message) {
    final surface = _surfaces[message['s']];
    final key = message['k'];
    if (surface == null || key is! String || key.isEmpty || key.length > 64) {
      return;
    }
    final budget = _NodeBudget(_maxDataNodes);
    final value = _sanitize(message['v'], budget);
    if (budget.exceeded) {
      // 界面在主线程构建：一次塞进几十万个节点会卡死整个页面，直接拒收。
      _bridge.log('error', 'setData("$key") 数据过大，已忽略');
      return;
    }
    surface.data.update(key, value ?? '');
  }

  /// 把 JSON 值规整成界面数据能接受的形态。
  ///
  /// rfw 的数据树只接受 map/list/int/double/bool/String，不接受 null：
  /// map 里的 null 项直接丢掉（界面里读到的是"缺失"），列表里的 null 换成
  /// 空串以保持下标不变。
  static Object? _sanitize(Object? value, _NodeBudget budget, [int depth = 0]) {
    if (depth > 32 || !budget.take()) {
      budget.exceeded = true;
      return null;
    }
    if (value is List) {
      final result = <Object?>[];
      for (final item in value) {
        result.add(_sanitize(item, budget, depth + 1) ?? '');
        if (budget.exceeded) return null;
      }
      return result;
    }
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final item = _sanitize(entry.value, budget, depth + 1);
        if (budget.exceeded) return null;
        if (item != null) result['${entry.key}'] = item;
      }
      return result;
    }
    return value;
  }

  void _handleTimer(Map<dynamic, dynamic> message) {
    final id = message['id'];
    if (id is! int) return;
    if (message['op'] == 'clear') {
      _timers.remove(id)?.cancel();
      return;
    }
    if (_timers.length >= _maxTimers || _timers.containsKey(id)) return;
    final ms = message['ms'];
    final requested = Duration(milliseconds: ms is num ? ms.toInt() : 0);
    final delay = requested.isNegative
        ? Duration.zero
        : (requested > _maxTimerDelay ? _maxTimerDelay : requested);
    _timers[id] = Timer(delay, () {
      _timers.remove(id);
      _run('__fluxdoMetaverse.timer($id)');
    });
  }
}

/// 单次 `setData` 允许的节点数预算。
class _NodeBudget {
  _NodeBudget(this._remaining);

  int _remaining;
  bool exceeded = false;

  bool take() {
    if (_remaining <= 0) {
      exceeded = true;
      return false;
    }
    _remaining--;
    return true;
  }
}
