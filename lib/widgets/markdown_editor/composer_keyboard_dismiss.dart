import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 手势只接管系统键盘的移动，不改变正文、选区或工具岛的展开状态。
class ComposerKeyboardDismissController extends ChangeNotifier
    with WidgetsBindingObserver {
  ComposerKeyboardDismissController({
    required TickerProvider vsync,
    TargetPlatform? platform,
  }) : _platform = platform ?? defaultTargetPlatform,
       _height = AnimationController.unbounded(vsync: vsync) {
    _height.addListener(notifyListeners);
    WidgetsBinding.instance.addObserver(this);
    _installChannelHandler();
  }

  static const _channel = MethodChannel('com.fluxdo/interactive_keyboard');
  static const settleDuration = Duration(milliseconds: 300);
  static final _sessions = <int, ComposerKeyboardDismissController>{};
  static int _nextSession = 0;
  static bool _handlerInstalled = false;
  static void _installChannelHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancelled') {
        final args = call.arguments as Map;
        _sessions[args['session']]?._systemCancelled();
      }
    });
  }

  final TargetPlatform _platform;
  final AnimationController _height;
  Future<bool>? _ready;
  int? _session;
  bool _disposed = false;
  bool _active = false;
  bool _interactive = false;
  bool _ending = false;
  double _initialHeight = 0;
  double _safeBottom = 0;
  double _screenHeight = 0;
  double _distance = 0;
  double _lastDelta = 0;
  bool get active => _active;
  double get visibleHeight => math.max(_safeBottom, _height.value);

  bool begin(ui.FlutterView view) {
    if (_disposed ||
        _session != null ||
        kIsWeb ||
        (_platform != TargetPlatform.iOS &&
            _platform != TargetPlatform.android)) {
      return false;
    }
    final height = view.viewInsets.bottom / view.devicePixelRatio;
    if (height <= 0) return false;
    _initialHeight = height;
    _safeBottom = view.viewPadding.bottom / view.devicePixelRatio;
    _screenHeight = view.physicalSize.height / view.devicePixelRatio;
    _distance = 0;
    _lastDelta = 0;
    _ending = false;
    _active = true;
    _interactive = false;
    _height.value = height;
    final session = _session = ++_nextSession;
    _sessions[session] = this;
    notifyListeners();
    _ready = _beginNative(session);
    return true;
  }

  Future<bool> _beginNative(int session) async {
    try {
      if (_platform == TargetPlatform.iOS) {
        // Flutter 3.44 的 iOS text-input 引擎通道。首次 move 接管键盘，
        // 后续 move 跟手；不要提前 TextInput.hide / unfocus，否则会丢来源。
        await SystemChannels.textInput.invokeMethod<void>(
          'TextInput.onPointerMoveForInteractiveKeyboard',
          {'pointerY': _screenHeight - _initialHeight},
        );
      } else {
        final ready = await _channel.invokeMapMethod<String, dynamic>('begin', {
          'session': session,
        });
        if (ready?['supported'] != true) {
          if (_session == session && !_disposed) {
            _active = false;
            notifyListeners();
          }
          return false;
        }
      }
      if (_disposed || _session != session) return false;
      _interactive = true;
      _height.value = _initialHeight - _distance;
      await _moveNative(session);
      return true;
    } on MissingPluginException {
      if (_session == session && !_disposed) {
        _active = false;
        notifyListeners();
      }
      return false;
    } on PlatformException {
      if (_session == session && !_disposed) {
        _active = false;
        notifyListeners();
      }
      return false;
    }
  }

  void update(double delta) {
    if (_session == null || _ending) return;
    _lastDelta = delta;
    _distance = (_distance + delta).clamp(0.0, _initialHeight);
    // 等系统授予控制权后再一起移动，不能让浮岛先滑进尚未移动的键盘。
    if (_active && _interactive) _height.value = _initialHeight - _distance;
    if (_interactive) unawaited(_moveNative(_session!));
  }

  Future<void> _moveNative(int session) async {
    try {
      if (_platform == TargetPlatform.iOS) {
        await SystemChannels.textInput.invokeMethod<void>(
          'TextInput.onPointerMoveForInteractiveKeyboard',
          {'pointerY': _screenHeight - _initialHeight + _distance},
        );
      } else {
        await _channel.invokeMethod<void>('update', {
          'session': session,
          'distance': _distance,
        });
      }
    } on PlatformException {
      _systemCancelled();
    } on MissingPluginException {
      _systemCancelled();
    }
  }

  Future<void> end(double velocity, {bool cancel = false}) async {
    final session = _session;
    if (session == null || _ending) return;
    _ending = true;
    final dismiss =
        !cancel &&
        (velocity > 180 ||
            (velocity >= -180 && _distance > 32 && _lastDelta >= 0));
    final ready = await _ready;
    if (_disposed || _session != session) return;
    if (ready != true) {
      if (dismiss) {
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
      _clear(session);
      return;
    }
    try {
      Future<void> native;
      if (_platform == TargetPlatform.iOS) {
        // 引擎以最后移动方向决定关闭/回位。末次微移用于传达松手意图，
        // 也处理“拖到一半后取消”的场景，不会额外改变可见几何。
        final y =
            _screenHeight - _initialHeight + _distance + (dismiss ? .1 : -.1);
        await SystemChannels.textInput.invokeMethod<void>(
          'TextInput.onPointerMoveForInteractiveKeyboard',
          {'pointerY': y},
        );
        native = SystemChannels.textInput.invokeMethod<void>(
          'TextInput.onPointerUpForInteractiveKeyboard',
          {'pointerY': y},
        );
      } else {
        native = _channel.invokeMethod<void>('end', {
          'session': session,
          'dismiss': dismiss,
        });
      }
      await Future.wait([
        native,
        _height
            .animateTo(
              dismiss ? _safeBottom : _initialHeight,
              duration: settleDuration,
              curve: Curves.easeInOut,
            )
            .orCancel,
      ]);
      // iOS 引擎恢复 firstResponder 后还有 100ms 的键盘快照交接。
      if (_platform == TargetPlatform.iOS && !dismiss) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!_disposed && _session == session) _clear(session);
    } on TickerCanceled {
      // 生命周期/系统取消已经释放了本次接管。
    } on PlatformException {
      _systemCancelled();
    } on MissingPluginException {
      _systemCancelled();
    }
  }

  void _clear(int session) {
    if (_session != session) return;
    _sessions.remove(session);
    _session = null;
    _active = false;
    _interactive = false;
    _ready = null;
    if (!_disposed) notifyListeners();
  }

  void _systemCancelled() {
    final session = _session;
    if (session == null || _disposed) return;
    _height.stop(canceled: true);
    _clear(session);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(end(0, cancel: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final session = _session;
    if (session != null) {
      // 页面销毁时仍需终结原生接管，尤其是 iOS 的键盘快照。
      if (_platform == TargetPlatform.android) {
        unawaited(
          _channel
              .invokeMethod<void>('cancel', {
                'session': session,
                'dismiss': true,
              })
              .catchError((_) {}),
        );
      } else {
        // 页面已离开，不能再恢复旧输入框的 firstResponder。
        final top = _screenHeight + 1;
        unawaited(
          SystemChannels.textInput
              .invokeMethod<void>(
                'TextInput.onPointerMoveForInteractiveKeyboard',
                {'pointerY': top},
              )
              .then(
                (_) => SystemChannels.textInput.invokeMethod<void>(
                  'TextInput.onPointerUpForInteractiveKeyboard',
                  {'pointerY': top},
                ),
              )
              .catchError((_) {}),
        );
      }
      _sessions.remove(session);
    }
    _disposed = true;
    _height.dispose();
    super.dispose();
  }
}

class ComposerKeyboardDismissScope extends InheritedWidget {
  const ComposerKeyboardDismissScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final ComposerKeyboardDismissController controller;
  static ComposerKeyboardDismissController? maybeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ComposerKeyboardDismissScope>()
          ?.controller;
  @override
  bool updateShouldNotify(ComposerKeyboardDismissScope oldWidget) =>
      controller != oldWidget.controller;
}
