import 'dart:async';

import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_function.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

typedef PromiseWithResolvers = (
  JSValue promise,
  JSFunction resolve,
  JSFunction reject,
);

/// Represents a JavaScript `Promise`.
///
/// Provides helpers for creating and bridging JavaScript promises with Dart.
extension type JSPromise._(JSValue value) implements JSValue {
  /// Returns a new promise and its resolve/reject functions.
  ///
  /// This corresponds to the `Promise.withResolvers()` JavaScript API.
  ///
  /// Example:
  /// ```dart
  /// final (promise, resolve, reject) = JSPromise.withResolvers(rt);
  /// resolve([JSValue.number(rt, 42)]);
  /// ```
  static PromiseWithResolvers withResolvers(JSRuntime rt) {
    final promiseFactory = rt.memoize(
      'Promise.withResolvers',
      () => rt.global['Promise'].asObject['withResolvers'].asFunctionUnsafe,
    );

    final promiseCtor = rt.memoize(
      'Promise',
      () => rt.global['Promise'],
    );

    final pwr = promiseFactory([], promiseCtor).asObject;

    final result = (
      pwr['promise'],
      pwr['resolve'].asFunctionUnsafe,
      pwr['reject'].asFunctionUnsafe,
    );

    return result;
  }

  /// Creates a JS promise that resolves when the Dart [fn] completes.
  ///
  /// This is the easiest way to expose async Dart logic to JavaScript.
  ///
  /// Example:
  /// ```dart
  /// final fn = JSFunction.createFromHostFunction(rt, (rt, _, __) {
  ///   return JSPromise.fromAsyncFunction(rt, () async {
  ///     await Future.delayed(const Duration(seconds: 1));
  ///     return JSValue.string(rt, 'Result from Dart');
  ///   });
  /// });
  /// rt.global['fetchData'] = fn.asValue;
  /// ```
  ///
  /// The runtime may be released while [fn] is awaiting. Using it after
  /// that throws a [StateError]; the result is then dropped, since there is
  /// no promise left to settle. Check `rt.isReleased` after an `await` to
  /// stop early.
  static JSValue fromAsyncFunction(
    JSRuntime rt,
    Future<JSValue> Function() fn,
  ) {
    final (promise, resolve, reject) = JSPromise.withResolvers(rt);

    // Settling the promise runs the script's continuations, which may fail
    // (e.g. when interrupted). Nobody awaits this callback, so report it.
    void settle(JSFunction settler, JSValue value) {
      try {
        settler([value]);
      } on JSException catch (error) {
        rt.onUncaughtError?.call(error);
      }
    }

    fn().then(
      (it) {
        if (!rt.isReleased) {
          settle(resolve, it);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!rt.isReleased) {
          final errValue = error is JSException
              ? error.value
              : JSError.create(rt, error.toString());

          settle(reject, errValue);
        }
      },
    );

    return promise;
  }

  JSPromise retain() => JSPromise._(value.retain());
}
