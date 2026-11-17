import 'dart:ffi';

import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

/// Represents a JavaScript `Symbol`.
///
/// Symbols are unique primitive values often used as property keys.
extension type JSSymbol(JSPointer jsPointer) implements Finalizable {
  /// Creates a new JavaScript symbol with an optional [description].
  ///
  /// Example:
  /// ```dart
  /// final sym = JSSymbol.create(rt, 'id');
  /// ```
  factory JSSymbol.create(JSRuntime rt, [String? description]) {
    final symbolCtor = rt.memoize(
      'Symbol',
      () => rt.global['Symbol'].asFunctionUnsafe,
    );

    if (description != null) {
      final strVal = JSValue.string(rt, description, attachFinalizer: false);

      try {
        final result = symbolCtor.call([strVal]);
        return result.asSymbol;
      } finally {
        strVal.release();
      }
    } else {
      final result = symbolCtor.call([]);
      return result.asSymbol;
    }
  }

  QJSABISymbol get ptr => jsPointer.asSymbol;

  JSRuntime get _rt => jsPointer.rt;

  /// Returns the string representation of this symbol.
  String getDescription() {
    final toStringFn = _rt.memoize(
      'Symbol.prototype.toString',
      () => _rt
          .global['Symbol']
          .asObject['prototype']
          .asObject['toString']
          .asFunctionUnsafe,
    );

    final res = toStringFn([], JSValue.fromSymbol(this));
    return res.asDartString;
  }

  bool strictEquals(JSSymbol other) {
    return jsPointer.strictEquals(other.jsPointer);
  }

  /// Increments the native reference count and returns a new handle to the
  /// same symbol.
  JSSymbol retain() {
    return JSSymbol(jsPointer.clone());
  }
}

extension JSPointerSymbolExt on JSPointer {
  QJSABISymbol get asSymbol => Struct.create()..pointer = handle;
}
