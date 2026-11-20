import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_string.dart';
import 'package:qjs/src/js_symbol.dart';
import 'package:qjs/src/utils.dart';

/// Represents a unique identifier for a JavaScript property.
///
/// [JSPropNameId] can be created from a string or a symbol and is used for
/// efficient property lookups on [JSObject].
///
/// Example:
/// ```dart
/// final propId = JSPropNameId.fromString(rt, 'id');
/// obj.setPropertyFromPropNameId(propId, JSValue.number(rt, 1));
/// ```
extension type JSPropNameId(JSPointer _pointer) implements Finalizable {
  /// Creates a property ID from a Dart [String].
  factory JSPropNameId.fromString(JSRuntime rt, String name) {
    final jsStr = JSString.fromString(rt, name, attachFinalizer: false);
    try {
      final result = qjs_propnameid_create_from_string(rt.ptr, jsStr.ptr);
      return JSPropNameId(
        JSPointer(rt, rt.unwrapManagedPtr(result.ptr_or_error)),
      );
    } finally {
      jsStr.jsPointer.release();
    }
  }

  /// Creates a property ID from a [JSSymbol].
  factory JSPropNameId.fromSymbol(JSRuntime rt, JSSymbol symbol) {
    final result = qjs_propnameid_create_from_symbol(rt.ptr, symbol.ptr);
    return JSPropNameId(
      JSPointer(rt, rt.unwrapManagedPtr(result.ptr_or_error)),
    );
  }

  @internal
  factory JSPropNameId.fromABI(
    JSRuntime rt,
    QJSABIPropNameID abi, {
    bool attachFinalizer = true,
  }) {
    return JSPropNameId(
      JSPointer(rt, abi.pointer, attachFinalizer: attachFinalizer),
    );
  }

  QJSABIPropNameID get ptr => _pointer.asPropNameId;

  JSRuntime get _rt => _pointer.rt;

  /// Returns the string representation of this property ID.
  String get string {
    return qjs_propnameid_get_data(_rt.ptr, ptr).toDartString();
  }

  /// Returns true if this property ID is equal to [other].
  bool equals(JSPropNameId other) {
    return qjs_propnameid_equals(_rt.ptr, ptr, other.ptr);
  }

  /// Increments the native reference count and returns a new handle to the
  /// same property ID.
  JSPropNameId retain() {
    final cloned = qjs_propnameid_clone(_rt.ptr, ptr);
    return JSPropNameId(JSPointer(_rt, cloned.pointer));
  }
}

extension JSPointerPropNameIdExt on JSPointer {
  QJSABIPropNameID get asPropNameId => Struct.create()..pointer = handle;
}
