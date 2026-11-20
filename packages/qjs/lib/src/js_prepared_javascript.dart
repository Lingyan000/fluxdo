import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';

/// A class representing compiled JavaScript bytecode.
class JSPreparedJavaScript implements Finalizable {
  @internal
  JSPreparedJavaScript(this._ptr) {
    _finalizer.attach(
      this,
      _ptr.cast(),
      detach: this,
      externalSize: 128,
    );
  }

  final Pointer<QJSABIPreparedJavaScript> _ptr;
  bool _released = false;

  static final _finalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(Pointer<QJSABIPreparedJavaScript>)>
        >(qjs_preparedjavascript_release)
        .cast(),
  );

  @internal
  Pointer<QJSABIPreparedJavaScript> get ptr {
    if (_released) {
      throw StateError('JSPreparedJavaScript has already been released.');
    }
    return _ptr;
  }

  /// Releases the prepared JavaScript.
  void release() {
    if (_released) return;
    _finalizer.detach(this);
    qjs_preparedjavascript_release(_ptr);
    _released = true;
  }
}
