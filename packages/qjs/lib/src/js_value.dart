import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_array.dart';
import 'package:qjs/src/js_array_buffer.dart';
import 'package:qjs/src/js_bigint.dart';
import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_function.dart';
import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_string.dart';
import 'package:qjs/src/js_symbol.dart';

/// The type of a JavaScript value.
enum JSValueType {
  undefined,
  null_,
  boolean,
  error,
  number,
  symbol,
  bigInt,
  string,
  object,
}

/// Represents a JavaScript value (primitive or object).
///
/// Example:
/// ```dart
/// final num = JSValue.number(rt, 42);
/// if (num.isNumber) {
///   print(num.asNumber); // 42.0
/// }
/// ```
class JSValue implements Finalizable {
  JSValue._(this._rt, this._raw, this._pointer);

  @internal
  factory JSValue.fromABI(
    JSRuntime rt,
    QJSABIValue value, {
    bool? attachFinalizer,
    JSPointer? jsPointer,
  }) {
    assert(
      jsPointer == null || attachFinalizer == null,
      'Cannot specify attachFinalizer when providing a pre-existing jsPointer.',
    );

    if (value.kind == .QJSABIValueKindError) {
      if (value.data.error == .QJSABIErrorCodeNativeException) {
        throw JSNativeException(rt.getAndClearNativeExceptionMessage());
      } else {
        throw JSException(rt.getAndClearJSErrorValue());
      }
    }

    jsPointer ??= (value.kind.value & 0x80000000) != 0
        ? JSPointer(
            rt,
            value.data.pointer,
            attachFinalizer: attachFinalizer ?? true,
          )
        : null;

    return JSValue._(rt, value, jsPointer);
  }

  @internal
  factory JSValue.fromObject(JSObject object) {
    return JSValue._(
      object.jsPointer.rt,
      Struct.create<QJSABIValue>()
        ..kind = .QJSABIValueKindObject
        ..data.pointer = object.jsPointer.handle,
      object.jsPointer,
    );
  }

  /// Parses a UTF-8 JSON byte array into a [JSValue].
  factory JSValue.fromJsonUtf8(JSRuntime rt, Uint8List jsonBytes) =>
      using((arena) {
        // JS_ParseJSON requires a NUL-terminated buffer.
        final nativeBytes = arena<Uint8>(jsonBytes.length + 1);
        nativeBytes.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
        nativeBytes[jsonBytes.length] = 0;
        final result = qjs_value_create_from_json_utf8(
          rt.ptr,
          nativeBytes,
          jsonBytes.length,
        );
        return JSValue.fromABI(rt, result.value);
      });

  @internal
  factory JSValue.fromString(JSString string) {
    return JSValue._(
      string.jsPointer.rt,
      Struct.create<QJSABIValue>()
        ..kind = .QJSABIValueKindString
        ..data.pointer = string.jsPointer.handle,
      string.jsPointer,
    );
  }

  @internal
  factory JSValue.fromSymbol(JSSymbol symbol) {
    return JSValue._(
      symbol.jsPointer.rt,
      Struct.create<QJSABIValue>()
        ..kind = .QJSABIValueKindSymbol
        ..data.pointer = symbol.jsPointer.handle,
      symbol.jsPointer,
    );
  }

  @internal
  factory JSValue.fromBigInt(JSBigInt bigInt) {
    return JSValue._(
      bigInt.jsPointer.rt,
      Struct.create<QJSABIValue>()
        ..kind = .QJSABIValueKindBigInt
        ..data.pointer = bigInt.jsPointer.handle,
      bigInt.jsPointer,
    );
  }

  /// Creates a [JSValue] representing `undefined`.
  factory JSValue.undefined(JSRuntime rt) {
    final value = Struct.create<QJSABIValue>()
      ..kind = .QJSABIValueKindUndefined;

    return JSValue.fromABI(rt, value);
  }

  /// Creates a [JSValue] representing `null`.
  factory JSValue.null_(JSRuntime rt) {
    final value = Struct.create<QJSABIValue>()..kind = .QJSABIValueKindNull;

    return JSValue.fromABI(rt, value);
  }

  /// Creates a [JSValue] from a Dart [bool].
  factory JSValue.boolean(JSRuntime rt, bool boolean) {
    final value = Struct.create<QJSABIValue>()
      ..kind = .QJSABIValueKindBoolean
      ..data.boolean = boolean;

    return JSValue.fromABI(rt, value);
  }

  /// Creates a [JSValue] from a Dart [double].
  factory JSValue.number(JSRuntime rt, double number) {
    final value = Struct.create<QJSABIValue>()
      ..kind = .QJSABIValueKindNumber
      ..data.number = number;

    return JSValue.fromABI(rt, value);
  }

  /// Creates a [JSValue] from a Dart [String].
  factory JSValue.string(
    JSRuntime rt,
    String string, {
    bool attachFinalizer = true,
  }) {
    final jsStr = JSString.fromString(
      rt,
      string,
      attachFinalizer: attachFinalizer,
    );

    final value = Struct.create<QJSABIValue>()
      ..kind = .QJSABIValueKindString
      ..data.pointer = jsStr.ptr.pointer;

    return JSValue.fromABI(rt, value, jsPointer: jsStr.jsPointer);
  }

  final JSRuntime _rt;
  final QJSABIValue _raw;
  final JSPointer? _pointer;

  QJSABIValue get ptr => _raw;
  JSPointer? get jsPointer => _pointer;

  /// Manually release this value if it holds a managed pointer.
  void release() {
    _pointer?.release();
  }

  /// Returns a guaranteed unique ID for this value.
  int get uniqueId {
    return qjs_value_get_unique_id(_rt.ptr, _raw);
  }

  /// Returns the type of this value.
  JSValueType get type => switch (_raw.kind) {
    .QJSABIValueKindUndefined => .undefined,
    .QJSABIValueKindNull => .null_,
    .QJSABIValueKindBoolean => .boolean,
    .QJSABIValueKindError => .error,
    .QJSABIValueKindNumber => .number,
    .QJSABIValueKindSymbol => .symbol,
    .QJSABIValueKindBigInt => .bigInt,
    .QJSABIValueKindString => .string,
    .QJSABIValueKindObject => .object,
  };

  bool get isUndefined => _raw.kind == .QJSABIValueKindUndefined;
  bool get isNull => _raw.kind == .QJSABIValueKindNull;
  bool get isBoolean => _raw.kind == .QJSABIValueKindBoolean;
  bool get isNumber => _raw.kind == .QJSABIValueKindNumber;
  bool get isString => _raw.kind == .QJSABIValueKindString;
  bool get isObject => _raw.kind == .QJSABIValueKindObject;
  bool get isError => _raw.kind == .QJSABIValueKindError;
  bool get isSymbol => _raw.kind == .QJSABIValueKindSymbol;
  bool get isBigInt => _raw.kind == .QJSABIValueKindBigInt;
  bool get isArray {
    if (_pointer case final pointer? when isObject) {
      return qjs_object_is_array(_rt.ptr, pointer.asObject);
    }
    return false;
  }

  bool get isArrayBuffer {
    if (_pointer case final pointer? when isObject) {
      return qjs_object_is_arraybuffer(_rt.ptr, pointer.asObject);
    }
    return false;
  }

  /// Returns this value as a [bool]. Throws if not a boolean.
  bool get asBoolean {
    if (!isBoolean) {
      throw StateError('JSValue is not a boolean (kind: ${_raw.kind})');
    }

    return _raw.data.boolean;
  }

  /// Returns this value as a [double]. Throws if not a number.
  double get asNumber {
    if (!isNumber) {
      throw StateError('JSValue is not a number (kind: ${_raw.kind})');
    }

    return _raw.data.number;
  }

  /// Returns this value as a [JSString]. Throws if not a string.
  JSString get asString {
    if (_pointer case final pointer? when isString) {
      return JSString(pointer);
    }

    throw StateError('JSValue is not a string (kind: ${_raw.kind})');
  }

  /// Returns this value as a Dart [String]. Throws if not a string.
  String get asDartString => asString.string;

  /// Returns this value as a [JSObject]. Throws if not an object.
  JSObject get asObject {
    if (_pointer case final pointer? when isObject) {
      return JSObject(pointer);
    }

    throw StateError('JSValue is not an object (kind: ${_raw.kind})');
  }

  /// Returns this value as a [JSFunction], or null if not a function.
  JSFunction? get asFunctionOrNull {
    if (!isObject) return null;

    final obj = asObject;
    if (!obj.isFunction) return null;

    return obj.asFunction;
  }

  /// Returns this value as a [JSFunction] without type checking.
  JSFunction get asFunctionUnsafe {
    return JSFunction(_pointer!);
  }

  /// Returns this value as a [JSSymbol]. Throws if not a symbol.
  JSSymbol get asSymbol {
    if (_pointer case final pointer? when isSymbol) {
      return JSSymbol(pointer);
    }

    throw StateError('JSValue is not a symbol (kind: ${_raw.kind})');
  }

  /// Returns this value as a [JSBigInt]. Throws if not a BigInt.
  JSBigInt get asBigInt {
    if (_pointer case final pointer? when isBigInt) {
      return JSBigInt(pointer);
    }

    throw StateError('JSValue is not a BigInt (kind: ${_raw.kind})');
  }

  /// Returns this value as a [JSArray]. Throws if not an array.
  JSArray get asArray {
    if (_pointer case final pointer? when isArray) {
      return JSArray(pointer);
    }

    throw StateError('JSValue is not an array');
  }

  /// Returns this value as a [JSArrayBuffer]. Throws if not an ArrayBuffer.
  JSArrayBuffer get asArrayBuffer {
    if (_pointer case final pointer? when isArrayBuffer) {
      return JSArrayBuffer(pointer);
    }

    throw StateError('JSValue is not an array buffer');
  }

  /// Returns true if this value is strictly equal to [other].
  bool strictEquals(JSValue other) {
    if (ptr.kind != other.ptr.kind) return false;

    return switch (ptr.kind) {
      .QJSABIValueKindUndefined => true,
      .QJSABIValueKindNull => true,
      .QJSABIValueKindBoolean => asBoolean == other.asBoolean,
      .QJSABIValueKindNumber => asNumber == other.asNumber,
      .QJSABIValueKindString => asString.strictEquals(other.asString),
      .QJSABIValueKindObject => asObject.strictEquals(other.asObject),
      .QJSABIValueKindSymbol => asSymbol.strictEquals(other.asSymbol),
      .QJSABIValueKindBigInt => asBigInt.strictEquals(other.asBigInt),
      .QJSABIValueKindError => false,
    };
  }

  /// Increments the native reference count and returns a new handle to the
  /// same JSValue.
  ///
  /// Use this when you need to keep a borrowed value (like an argument from
  /// a HostFunction) alive beyond its current scope.
  JSValue retain() {
    if (isObject) return JSValue.fromObject(asObject.retain());
    if (isString) return JSValue.fromString(asString.retain());
    if (isSymbol) return JSValue.fromSymbol(asSymbol.retain());
    if (isBigInt) return JSValue.fromBigInt(asBigInt.retain());

    final val = Struct.create<QJSABIValue>()
      ..kind = _raw.kind
      ..data.pointer = _raw.data.pointer;

    return JSValue._(_rt, val, null);
  }
}
