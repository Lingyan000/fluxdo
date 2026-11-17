import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

/// A weak reference to a JavaScript object.
///
/// This allows you to hold a reference to a JS object without preventing
/// it from being garbage collected.
extension type JSWeakObject(JSPointer jsPointer) {
  /// Creates a weak reference to the given [object].
  factory JSWeakObject.create(JSRuntime rt, JSObject object) {
    final weakRefCtor = rt.memoize(
      'WeakRef',
      () => rt.global['WeakRef'].asFunctionUnsafe,
    );
    final val = JSValue.fromObject(object);
    final ref = weakRefCtor.callAsConstructor([val]);
    return JSWeakObject(ref.asObject.jsPointer);
  }

  JSRuntime get _rt => jsPointer.rt;

  JSObject get asObject => JSObject(jsPointer);

  /// Attempts to lock the weak reference and return a strong reference
  /// to the object.
  ///
  /// Returns a [JSValue] that represents the object if it is still alive,
  /// or an `undefined` value if the object has been garbage collected.
  JSValue lock() {
    final derefFn = _rt.memoize(
      'WeakRef.prototype.deref',
      () => _rt
          .global['WeakRef']
          .asObject['prototype']
          .asObject['deref']
          .asFunctionUnsafe,
    );
    return derefFn([], JSValue.fromObject(asObject));
  }
}
