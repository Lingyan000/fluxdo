import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_prop_id.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

typedef JSHostFunction = JSValue Function(
  JSRuntime rt,
  JSValue thisValue,
  List<JSValue> args,
);

final Map<int, JSHostFunction> _hostFunctionsRegistry = {};
int _nextHostFunctionId = 1;

/// Represents a JavaScript `Function`.
///
/// Use [JSFunction.createFromHostFunction] to expose Dart code to JavaScript.
/// To call a JavaScript function from Dart, obtain a [JSFunction] instance via
/// [JSValue.asFunctionOrNull], [JSValue.asFunctionUnsafe], or
/// [JSObject.asFunction].
///
/// Example:
/// ```dart
/// final fn = rt.evaluateJavascript('(a, b) => a + b').asFunctionOrNull!;
/// final sum = fn([JSValue.number(rt, 1), JSValue.number(rt, 2)]);
/// ```
extension type JSFunction(JSPointer jsPointer) implements Finalizable {
  /// Creates a JavaScript function that calls a Dart [fn].
  ///
  /// [name] and [length] are used to set the `name` and `length` properties
  /// of the resulting JavaScript function object.
  ///
  /// Example:
  /// ```dart
  /// final fn = JSFunction.createFromHostFunction(rt, (rt, thisArg, args) {
  ///   if (args.isEmpty) {
  ///     throw JSException(JSError.typeError(rt, 'Argument required'));
  ///   }
  ///   return JSValue.string(rt, 'Hello ${args[0].asDartString}');
  /// });
  /// ```
  factory JSFunction.createFromHostFunction(
    JSRuntime rt,
    JSHostFunction fn, {
    String name = 'anonymous',
    int length = 0,
  }) {
    final id = _nextHostFunctionId++;
    _hostFunctionsRegistry[id] = fn;

    final propId = JSPropNameId.fromString(rt, name);

    final result = qjs_function_create_from_host(
      rt.ptr,
      propId.ptr,
      length,
      Pointer.fromAddress(id),
      _hostFunctionCallCallable.nativeFunction,
      _hostFunctionReleaseCallable.nativeFunction,
    );

    return JSFunction(JSPointer(rt, rt.unwrapManagedPtr(result.ptr_or_error)));
  }

  QJSABIFunction get ptr => jsPointer.asFunction;

  JSRuntime get _rt => jsPointer.rt;

  JSObject get asObject => JSObject(jsPointer);

  JSValue get asValue => JSValue.fromObject(asObject);

  /// Calls the function with optional [args] and [thisValue].
  JSValue call([List<JSValue>? args, JSValue? thisValue]) {
    final argCount = args?.length ?? 0;
    final jsArgs = argCount != 0 ? calloc<QJSABIValue>(argCount) : nullptr;
    for (var i = 0; i < argCount; i++) {
      jsArgs[i] = args![i].ptr;
    }

    try {
      final result = qjs_function_call(
        _rt.ptr,
        ptr,
        thisValue?.ptr ?? JSValue.undefined(_rt).ptr,
        jsArgs,
        argCount,
      );

      return JSValue.fromABI(_rt, result);
    } finally {
      calloc.free(jsArgs);
    }
  }

  /// Calls the function as a constructor.
  ///
  /// Example:
  /// ```dart
  /// final urlCtor = rt.global['URL'].asObject.asFunction;
  /// final url = urlCtor.callAsConstructor([
  ///   JSValue.string(rt, 'https://example.com'),
  /// ]);
  /// ```
  JSValue callAsConstructor([List<JSValue>? args]) {
    final argCount = args?.length ?? 0;
    final jsArgs = argCount != 0 ? calloc<QJSABIValue>(argCount) : nullptr;
    for (var i = 0; i < argCount; i++) {
      jsArgs[i] = args![i].ptr;
    }

    try {
      final result = qjs_function_call_as_constructor(
        _rt.ptr,
        ptr,
        jsArgs,
        argCount,
      );

      return JSValue.fromABI(_rt, result);
    } finally {
      calloc.free(jsArgs);
    }
  }

  /// Increments the native reference count and returns a new handle to the
  /// same function.
  JSFunction retain() {
    return JSFunction(jsPointer.clone());
  }
}

extension JSPointerFunctionExt on JSPointer {
  QJSABIFunction get asFunction => Struct.create()..pointer = handle;
}

final _hostFunctionReleaseCallable =
    NativeCallable<QJSABIHostFunctionReleaseFunction>.listener(
      (Pointer<Void> userData) {
        _hostFunctionsRegistry.remove(userData.address);
      },
    )..keepIsolateAlive = false;

final _hostFunctionCallCallable =
    NativeCallable<QJSABIHostFunctionCallFunction>.isolateLocal((
      Pointer<Void> userData,
      Pointer<QJSABIRuntime> runtime,
      Pointer<QJSABIValue> thisArg,
      Pointer<QJSABIValue> args,
      int count,
    ) {
      final fn = _hostFunctionsRegistry[userData.address]!;
      final rt = JSRuntime(runtime);

      try {
        final result = fn(
          rt,
          JSValue.fromABI(rt, thisArg.ref, attachFinalizer: false),
          List.generate(
            count,
            (i) => JSValue.fromABI(rt, args[i], attachFinalizer: false),
          ),
        );

        final retained = result.retain();
        // Retain the returned value to balance the reference counting.
        //
        // In the C++ bridge (HostFunctionWrapper::call in
        // qjs_vtable.cpp), the VM consumes the returned
        // QJSABIValue and then immediately decrements its refcount:
        //
        //   auto ret = abi::getValue(retOrError);
        //   auto retHV = toHermesValue(ret);
        //   abi::releaseValue(ret); // <-- Decrements refcount by 1
        //   return retHV;
        //
        // To prevent this decrement from causing a Use-After-Free or
        // Double-Free on Dart-owned values (especially if they are
        // shared or cached), we increment the refcount via
        // `result.retain()`. However, `retain()` returns a new
        // `JSValue` with a new finalizer attached. If we don't detach
        // it, its finalizer will decrement the refcount again when
        // collected by Dart GC, neutralizing the retain.
        //
        // Thus, we call `retained.jsPointer?.detachFinalizer()` on the
        // new copy to prevent the extra decrement while keeping the
        // original `result`'s finalizer intact and active.
        retained.jsPointer?.detachFinalizer();

        return (Struct.create<QJSABIValueOrError>()..value = retained.ptr);
      } on JSException catch (error) {
        rt.setJSErrorValue(error.value);
        return (Struct.create<QJSABIValueOrError>()
          ..value.kind = .QJSABIValueKindError
          ..value.data.error = .QJSABIErrorCodeJSError);
      } on JSNativeException catch (error) {
        rt.setNativeExceptionMessage(error.message);
        return (Struct.create<QJSABIValueOrError>()
          ..value.kind = .QJSABIValueKindError
          ..value.data.error = .QJSABIErrorCodeNativeException);
      } catch (error) {
        rt.setNativeExceptionMessage(error.toString());
        return (Struct.create<QJSABIValueOrError>()
          ..value.kind = .QJSABIValueKindError
          ..value.data.error = .QJSABIErrorCodeNativeException);
      }
    })..keepIsolateAlive = false;
