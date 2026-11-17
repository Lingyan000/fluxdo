import 'package:logging/logging.dart';
import 'package:qjs/qjs.dart';

/// Bridge between the JavaScript `console` API and Dart [Logger].
///
/// Implements `log`, `info`, `warn`, `error`, and `debug`.
class JSConsole {
  /// Installs `console` into the global scope of [rt].
  ///
  /// JS arguments are stringified and joined with spaces before
  /// being passed to [_logger].
  JSConsole.install(JSRuntime rt, {required this._logger}) : _rt = rt {
    _log = _createLogJSFn(.INFO);
    _info = _createLogJSFn(.INFO);
    _warn = _createLogJSFn(.WARNING);
    _error = _createLogJSFn(.SEVERE);
    _debug = _createLogJSFn(.FINE);

    final console = JSObject.create(rt)
      ..['log'] = _log.asValue
      ..['info'] = _info.asValue
      ..['warn'] = _warn.asValue
      ..['error'] = _error.asValue
      ..['debug'] = _debug.asValue
      ..freeze();

    rt.global.defineProperty('console', value: console.asValue);
  }

  final JSRuntime _rt;
  final Logger _logger;
  late final JSFunction _log;
  late final JSFunction _info;
  late final JSFunction _warn;
  late final JSFunction _error;
  late final JSFunction _debug;

  JSFunction _createLogJSFn(Level level) {
    final jsStringFn = _rt.global['String'].asFunctionUnsafe;

    return JSFunction.createFromHostFunction(_rt, (rt, thisValue, args) {
      final out = args
          .map((value) => jsStringFn([value]).asDartString)
          .join(' ');

      _logger.log(level, out);

      return .undefined(rt);
    });
  }
}
