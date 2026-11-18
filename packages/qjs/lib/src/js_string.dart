import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/utils.dart';

/// Represents a JavaScript string.
///
/// Example:
/// ```dart
/// final jsStr = JSString.fromString(rt, 'hello');
/// print(jsStr.string); // 'hello'
/// ```
extension type JSString(JSPointer jsPointer) implements Finalizable {
  /// Creates a new JavaScript string from a Dart [string]
  factory JSString.fromString(
    JSRuntime rt,
    String string, {
    bool attachFinalizer = true,
  }) {
    final cString = string.toNativeUtf8();

    try {
      final result = qjs_create_string_from_utf8(rt.ptr, cString.cast());

      return JSString(
        JSPointer(
          rt,
          rt.unwrapManagedPtr(result.ptr_or_error),
          attachFinalizer: attachFinalizer,
        ),
      );
    } finally {
      malloc.free(cString);
    }
  }

  JSRuntime get _rt => jsPointer.rt;

  QJSABIString get ptr => jsPointer.asString;

  /// Returns this JavaScript string as a Dart [String].
  String get string {
    return qjs_string_get_data(_rt.ptr, ptr).toDartString();
  }

  /// Returns true if this string is equal to [other].
  bool strictEquals(JSString other) {
    return jsPointer.strictEquals(other.jsPointer);
  }

  /// Increments the native reference count and returns a new handle to the
  /// same JSString.
  JSString retain() {
    return JSString(jsPointer.clone());
  }
}

extension JSPointerStringExt on JSPointer {
  QJSABIString get asString => Struct.create()..pointer = handle;
}
