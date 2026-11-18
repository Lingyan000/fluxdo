import 'dart:ffi';

import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

/// Represents a JavaScript `BigInt`.
///
/// Use [JSBigInt.fromInt] or [JSBigInt.fromBigInt] to create a new `BigInt`,
/// or [JSValue.asBigInt] to access an existing one.
extension type JSBigInt(JSPointer jsPointer) {
  /// Creates a `BigInt` from a 64-bit integer.
  factory JSBigInt.fromInt(JSRuntime rt, int value) {
    final result = qjs_bigint_create_from_int64(rt.ptr, value);
    return JSBigInt(JSPointer(rt, rt.unwrapManagedPtr(result.ptr_or_error)));
  }

  /// Creates a `BigInt` from a Dart [BigInt].
  factory JSBigInt.fromBigInt(JSRuntime rt, BigInt value) {
    if (value.isValidInt) {
      return JSBigInt.fromInt(rt, value.toInt());
    }

    final biCtor = rt.memoize(
      'BigInt',
      () => rt.global['BigInt'].asFunctionUnsafe,
    );
    final strVal = JSValue.string(
      rt,
      value.toString(),
      attachFinalizer: false,
    );
    try {
      final res = biCtor.call([strVal]);
      return res.asBigInt;
    } finally {
      strVal.release();
    }
  }

  QJSABIBigInt get ptr => jsPointer.asBigInt;

  JSRuntime get _rt => jsPointer.rt;

  /// Returns true if this `BigInt` fits in a 64-bit integer.
  bool isInt() => qjs_bigint_is_int64(_rt.ptr, ptr);

  /// Returns this `BigInt` as a 64-bit integer.
  int asInt() {
    if (!isInt()) {
      throw StateError('BigInt does not fit in int64');
    }
    return qjs_bigint_as_int64(_rt.ptr, ptr);
  }

  /// Returns this `BigInt` wrapped as a [JSValue].
  JSValue get asValue => JSValue.fromBigInt(this);

  /// Returns a string representation of this `BigInt` in the given [radix].
  String toRadixString({int radix = 10}) {
    final toStringFn = _rt.memoize(
      'BigInt.prototype.toString',
      () => _rt
          .global['BigInt']
          .asObject['prototype']
          .asObject['toString']
          .asFunctionUnsafe,
    );
    final res = toStringFn([JSValue.number(_rt, radix.toDouble())], asValue);
    return res.asDartString;
  }

  /// Converts this `BigInt` to a Dart [BigInt].
  BigInt toBigInt() {
    if (isInt()) {
      return BigInt.from(asInt());
    }
    return BigInt.parse(toRadixString());
  }

  bool strictEquals(JSBigInt other) {
    return jsPointer.strictEquals(other.jsPointer);
  }

  /// Increments the native reference count and returns a new handle to the
  /// same BigInt.
  JSBigInt retain() {
    return JSBigInt(jsPointer.clone());
  }
}

extension JSPointerBigIntExt on JSPointer {
  QJSABIBigInt get asBigInt => Struct.create()..pointer = handle;
}
