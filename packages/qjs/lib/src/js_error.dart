import 'package:qjs/src/js_function.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

extension on JSRuntime {
  JSFunction findConstructor(String name) {
    return memoize(
      'Error.$name',
      () => global[name].asFunctionUnsafe,
    );
  }
}

/// Represents a JavaScript `Error` object.
///
/// Example:
/// ```dart
/// final error = JSError.typeError(rt, 'Invalid argument');
/// throw JSException(error);
/// ```
extension type JSError._(JSValue value) implements JSValue {
  /// Creates a standard `Error`.
  JSError.create(JSRuntime rt, String message)
    : value = JSError._create(rt, rt.findConstructor('Error'), message);

  /// Creates a `TypeError`.
  JSError.typeError(JSRuntime rt, String message)
    : value = JSError._create(rt, rt.findConstructor('TypeError'), message);

  /// Creates a `ReferenceError`.
  JSError.referenceError(JSRuntime rt, String message)
    : value = JSError._create(
        rt,
        rt.findConstructor('ReferenceError'),
        message,
      );

  /// Creates a `SyntaxError`.
  JSError.syntaxError(JSRuntime rt, String message)
    : value = JSError._create(rt, rt.findConstructor('SyntaxError'), message);

  /// Creates a `RangeError`.
  JSError.rangeError(JSRuntime rt, String message)
    : value = JSError._create(rt, rt.findConstructor('RangeError'), message);

  /// Creates a `URIError`.
  JSError.uriError(JSRuntime rt, String message)
    : value = JSError._create(rt, rt.findConstructor('URIError'), message);

  factory JSError._create(
    JSRuntime rt,
    JSFunction constructor,
    String message,
  ) {
    final strVal = JSValue.string(rt, message, attachFinalizer: false);

    try {
      final error = constructor.callAsConstructor([strVal]);
      return JSError._(error);
    } finally {
      strVal.release();
    }
  }

  /// Increments the native reference count and returns a new handle to the
  /// same error object.
  JSError retain() => JSError._(value.retain());
}

/// An exception thrown when JavaScript code throws an error.
///
/// The [value] contains the thrown JavaScript value (usually an `Error`).
class JSException implements Exception {
  JSException(this.value);

  final JSValue value;

  @override
  String toString() {
    if (value.isObject) {
      final obj = value.asObject;

      try {
        final message = obj.getProperty('message');
        final stack = obj.getProperty('stack');

        var result = 'JSException: ';
        if (message.isString) {
          result += message.asDartString;
        } else {
          result += '[object]';
        }

        if (stack.isString) {
          result += '\n${stack.asDartString}';
        }
        return result;
      } catch (_) {
        return 'JSException: [object]';
      }
    }

    if (value.isString) return 'JSException: ${value.asDartString}';

    return 'JSException: [kind ${value.ptr.kind}]';
  }
}

/// An exception thrown when a native Hermes API call fails.
class JSNativeException implements Exception {
  JSNativeException(this.message);

  final String message;

  @override
  String toString() => 'JSNativeException: $message';
}
