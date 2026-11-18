import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_runtime.dart';

typedef _QJSManagedPointerReleaseFn =
    NativeFunction<Void Function(Pointer<QJSABIManagedPointer>)>;

class JSPointer implements Finalizable {
  JSPointer(
    this.rt,
    Pointer<QJSABIManagedPointer> handle, {
    this.externalSize = 128,
    this.attachFinalizer = true,
  }) : _handle = handle {
    if (attachFinalizer) {
      qjs_register_pointer(rt.ptr, _handle);
      _finalizer.attach(
        this,
        _handle.cast<Void>(),
        detach: this,
        externalSize: externalSize,
      );
    }
  }

  static NativeFinalizer _createFinalizer() {
    final ptr = Native.addressOf<_QJSManagedPointerReleaseFn>(
      qjs_pointer_release_safe,
    );

    return NativeFinalizer(ptr.cast());
  }

  static final NativeFinalizer _finalizer = _createFinalizer();

  @internal
  final JSRuntime rt;

  final Pointer<QJSABIManagedPointer> _handle;

  @internal
  final int? externalSize;

  final bool attachFinalizer;
  bool _released = false;

  bool get isReleased => _released;

  @internal
  Pointer<QJSABIManagedPointer> get handle {
    if (_released) {
      throw StateError('Attempted to use a released JSPointer.');
    }
    return _handle;
  }

  void detachFinalizer() => _finalizer.detach(this);

  /// Manually release the underlying pointer immediately.
  void release() {
    if (_released) return;
    _released = true;
    if (attachFinalizer) {
      detachFinalizer();
      qjs_pointer_release_safe(_handle);
    } else {
      qjs_pointer_release(_handle);
    }
  }

  /// Clones the managed pointer, incrementing the native reference count.
  JSPointer clone() {
    final clonedHandle = qjs_managed_pointer_clone(rt.ptr, handle);
    return JSPointer(
      rt,
      clonedHandle,
      externalSize: externalSize ?? 128,
      attachFinalizer: attachFinalizer,
    );
  }

  /// Checks strict equality with another managed pointer.
  bool strictEquals(JSPointer other) {
    return qjs_managed_pointer_strict_equals(rt.ptr, handle, other.handle);
  }
}
