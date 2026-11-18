import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/extensions/js_modules.dart';
import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_function.dart';
import 'package:qjs/src/js_module_loader.dart';
import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_prepared_javascript.dart';
import 'package:qjs/src/js_runtime_config.dart';
import 'package:qjs/src/js_runtime_controls.dart';
import 'package:qjs/src/js_value.dart';

final Map<int, WeakReference<JSRuntime>> _runtimesRegistry = {};

class JSRuntime implements Finalizable {
  factory JSRuntime(Pointer<QJSABIRuntime> ptr) {
    final cached = _runtimesRegistry[ptr.address]?.target;
    if (cached != null) return cached;

    final rt = JSRuntime._(ptr);
    _runtimesRegistry[ptr.address] = WeakReference(rt);
    return rt;
  }

  JSRuntime._(this._ptr);

  JSRuntime.create([
    JSRuntimeConfig config = const JSRuntimeConfig.hardened(),
  ]) : _ptr = _createRuntime(config) {
    _finalizer.attach(this, _ptr, detach: this);
    _runtimesRegistry[_ptr.address] = WeakReference(this);
  }

  static Pointer<QJSABIRuntime> _createRuntime(JSRuntimeConfig config) {
    final struct = Struct.create<QJSABIRuntimeConfig>()
      ..enable_eval = config.enableEval
      ..es6_proxy = config.es6Proxy
      ..microtask_queue = config.microtaskQueue
      ..memory_limit = config.memoryLimit
      ..max_stack_size = config.maxStackSize
      ..gc_threshold = config.gcThreshold;
    return qjs_runtime_create(struct);
  }

  // A Dart Finalizer rather than a NativeFinalizer: releasing a runtime runs
  // JS finalizers that call back into Dart through NativeCallable.listener,
  // which must not happen inside a GC.
  static final Finalizer<Pointer<QJSABIRuntime>> _finalizer = Finalizer((ptr) {
    if (_runtimesRegistry[ptr.address]?.target == null) {
      _runtimesRegistry.remove(ptr.address);
    }
    qjs_runtime_release(ptr);
  });

  final Pointer<QJSABIRuntime> _ptr;
  bool _released = false;

  /// The native runtime. Throws a [StateError] once the runtime has been
  /// released, since the native context no longer exists.
  @internal
  Pointer<QJSABIRuntime> get ptr {
    if (_released) {
      throw StateError('JSRuntime has been released.');
    }
    return _ptr;
  }

  bool get isReleased => _released;

  final Map<String, Object> _memoizedCache = {};

  JSObject? _globalThis;

  JSObject get global {
    return _globalThis ??= JSObject(
      JSPointer(
        this,
        qjs_runtime_get_global_object(ptr).pointer,
      ),
    );
  }

  @internal
  T memoize<T>(String key, T Function() builder) {
    final cached = _memoizedCache[key];
    if (cached != null) return cached as T;

    final value = builder();
    _memoizedCache[key] = value as Object;
    return value;
  }

  JSValue evaluateJavascript(
    String script, {
    String sourceUrl = 'script.js',
  }) => using((arena) {
    final nativeScript = script.toNativeUtf8(allocator: arena);
    final nativeSource = sourceUrl.toNativeUtf8(allocator: arena);

    final result = qjs_evaluate_javascript(
      ptr,
      nativeScript.cast(),
      nativeScript.length,
      nativeSource.cast(),
    );

    return JSValue.fromABI(this, result);
  });

  /// Prepares JavaScript source code for execution.
  JSPreparedJavaScript prepareJavaScript(
    String source, {
    String sourceUrl = 'script.js',
  }) => using((arena) {
    final nativeSourceUrl = sourceUrl.toNativeUtf8(allocator: arena);
    final nativeSource = source.toNativeUtf8(allocator: arena);
    final res = qjs_runtime_prepared_javascript_create(
      ptr,
      nativeSource.cast(),
      nativeSource.length,
      nativeSourceUrl.cast(),
    );
    return JSPreparedJavaScript(unwrapPtr(res.ptr_or_error));
  });

  /// Evaluates prepared JavaScript bytecode.
  JSValue evaluatePreparedJavaScript(JSPreparedJavaScript prepared) {
    final result = qjs_runtime_prepared_javascript_evaluate(
      ptr,
      prepared.ptr,
    );
    return JSValue.fromABI(this, result.value);
  }

  JSModuleLoader? _moduleLoader;

  /// Resolves and loads the modules imported by JavaScript code, usually a
  /// [JSModules]. Without one, which is the default, every import fails.
  ///
  /// Modules loaded through a previous loader stay cached.
  JSModuleLoader? get moduleLoader => _moduleLoader;

  set moduleLoader(JSModuleLoader? loader) {
    qjs_runtime_set_module_loader(
      ptr,
      loader == null ? nullptr : moduleResolveFunction,
      loader == null ? nullptr : moduleLoadFunction,
    );
    _moduleLoader = loader;
  }

  @internal
  int moduleLoaderDepth = 0;

  final Map<String, JSObject> _importedModules = {};

  /// Evaluates [source] as a module named [name] and returns its namespace,
  /// the object `import * as ns` gives, once its top-level `await` is done.
  ///
  /// Its imports go through [moduleLoader], relative to [name]. Like an
  /// inline `<script type="module">`, every call evaluates [source] again,
  /// unlike [importModule]. QuickJS never unloads modules, so each call
  /// keeps its module in memory until [release]; prefer [importModule] or
  /// [evaluateJavascript] for code that runs repeatedly.
  ///
  /// Once evaluated, the module is what later imports of [name] get, in
  /// place of the module [moduleLoader] would load.
  ///
  /// Completes with a [JSException] if the module fails to load or throws.
  /// With `microtaskQueue` enabled, the module only progresses while
  /// [drainMicrotasks] runs. If the runtime is released first, the future
  /// never completes.
  Future<JSObject> evaluateModule(
    String source, {
    String name = 'module.js',
  }) async {
    final (namespace, promise) = _evaluateModule(source, name);
    return _waitForNamespace(namespace, promise, name);
  }

  /// Same as [evaluateModule], but returns right away.
  ///
  /// Throws a [StateError] if the module's top-level `await` is still
  /// waiting, for example on a Dart future.
  JSObject evaluateModuleSync(String source, {String name = 'module.js'}) {
    final (namespace, promise) = _evaluateModule(source, name);
    return _settledNamespace(namespace, promise, name);
  }

  /// Imports the module [name] through [moduleLoader] and returns its
  /// namespace, like `import * as ns from name`.
  ///
  /// A module is loaded and evaluated once: later imports of the same
  /// canonical name, here or from JavaScript, reuse it.
  ///
  /// Completes like [evaluateModule].
  Future<JSObject> importModule(String name) async {
    final cached = _importedModules[name];
    if (cached != null) return cached;

    final (namespace, promise) = _evaluateModule(_importSource(name), '');
    final imported = await _waitForNamespace(namespace, promise, name);
    return _importedModules[name] = imported['default'].asObject;
  }

  /// Same as [importModule], but returns right away. Throws like
  /// [evaluateModuleSync].
  JSObject importModuleSync(String name) {
    final cached = _importedModules[name];
    if (cached != null) return cached;

    final (namespace, promise) = _evaluateModule(_importSource(name), '');
    return _importedModules[name] = _settledNamespace(
      namespace,
      promise,
      name,
    )['default'].asObject;
  }

  // A module importing [name] relative to an empty referrer.
  static String _importSource(String name) =>
      'import * as ns from ${jsonEncode(name)};\nexport default ns;\n';

  (JSValue, JSValue) _evaluateModule(String source, String name) {
    if (moduleLoaderDepth > 0) {
      throw StateError(
        'Cannot evaluate a module while the module loader is running.',
      );
    }
    return using((arena) {
      final nativeSource = source.toNativeUtf8(allocator: arena);
      final nativeName = name.toNativeUtf8(allocator: arena);
      final outPromise = arena<QJSABIValue>();
      final result = qjs_runtime_evaluate_module(
        ptr,
        nativeSource.cast(),
        nativeSource.length,
        nativeName.cast(),
        outPromise,
      );
      final namespace = JSValue.fromABI(this, result.value);
      // Copied out of the arena, which is freed on return.
      final promise = Struct.create<QJSABIValue>()
        ..kind = outPromise.ref.kind
        ..data.pointer = outPromise.ref.data.pointer;
      return (namespace, JSValue.fromABI(this, promise));
    });
  }

  JSObject _settledNamespace(JSValue namespace, JSValue promise, String name) {
    final state = qjs_promise_get_state(ptr, promise.asObject.ptr);
    return switch (state) {
      .QJSABIPromiseStateFulfilled => namespace.asObject,
      .QJSABIPromiseStateRejected => throw JSException(
        JSValue.fromABI(
          this,
          qjs_promise_get_result(ptr, promise.asObject.ptr),
        ),
      ),
      _ => throw StateError(
        "Module '$name' is still evaluating: its top-level await is "
        'waiting. Use the async variant to wait for it.',
      ),
    };
  }

  Future<JSObject> _waitForNamespace(
    JSValue namespace,
    JSValue promise,
    String name,
  ) {
    final state = qjs_promise_get_state(ptr, promise.asObject.ptr);
    if (state != .QJSABIPromiseStatePending) {
      return Future.sync(() => _settledNamespace(namespace, promise, name));
    }

    final completer = Completer<JSObject>();
    final onFulfilled = JSFunction.createFromHostFunction(this, (rt, _, _) {
      completer.complete(namespace.asObject);
      return .undefined(rt);
    });
    final onRejected = JSFunction.createFromHostFunction(this, (rt, _, args) {
      completer.completeError(
        JSException(args.isEmpty ? .undefined(rt) : args.first.retain()),
      );
      return .undefined(rt);
    });
    final result = qjs_promise_then(
      ptr,
      promise.asObject.ptr,
      onFulfilled.ptr,
      onRejected.ptr,
    );
    unwrapVoid(result.void_or_error);
    return completer.future;
  }

  /// Interrupts JavaScript execution once [timeout] has passed from now.
  ///
  /// The interrupted code throws an uncatchable `InternalError: interrupted`,
  /// which surfaces as a [JSException]; the runtime stays usable. The
  /// deadline stays in effect until [clearDeadline] or the next
  /// [setDeadline], so once it has passed every later execution, including
  /// pending microtasks, is interrupted immediately.
  void updateStackTop() => qjs_runtime_update_stack_top(ptr);

  void setDeadline(Duration timeout) {
    qjs_runtime_set_deadline(
      ptr,
      timeout.isNegative ? 0 : timeout.inMicroseconds,
    );
  }

  /// Removes the deadline set by [setDeadline].
  void clearDeadline() => qjs_runtime_clear_deadline(ptr);

  /// A handle that interrupts this runtime from any isolate.
  JSInterruptHandle get interruptHandle =>
      JSInterruptHandle(ptr.address, qjs_runtime_get_id(ptr));

  /// Interrupts the running JavaScript execution, or the next one if none
  /// is running. See [JSInterruptHandle.requestInterrupt].
  void requestInterrupt() => interruptHandle.requestInterrupt();

  /// The runtime's current memory usage.
  JSMemoryUsage get memoryUsage =>
      JSMemoryUsage.fromABI(qjs_runtime_get_memory_usage(ptr));

  /// Runs the JavaScript garbage collector.
  void runGC() => qjs_runtime_run_gc(ptr);

  JSUnhandledRejectionCallback? _onUnhandledRejection;

  /// Called when a promise is rejected without a handler, and again if a
  /// handler is attached later. Set to null to stop tracking.
  JSUnhandledRejectionCallback? get onUnhandledRejection =>
      _onUnhandledRejection;

  set onUnhandledRejection(JSUnhandledRejectionCallback? callback) {
    _onUnhandledRejection = callback;
    qjs_runtime_set_promise_rejection_tracker(
      ptr,
      callback == null
          ? nullptr
          : _promiseRejectionTrackerCallable.nativeFunction,
    );
  }

  /// Called with errors from JavaScript that runs with no Dart caller to
  /// throw to:
  ///
  /// - microtasks that fail while a `JSPromise.fromAsyncFunction` result
  ///   settles the JS promise. A script interrupted by [setDeadline] after
  ///   awaiting a host call ends up here, and its own promise never settles;
  /// - `setTimeout` / `setInterval` callbacks installed by `JSTimers`.
  ///
  /// If null, such errors are dropped.
  void Function(JSException error)? onUncaughtError;

  /// Drains the microtask queue.
  ///
  /// Throws a [JSException] if a microtask fails, for example because the
  /// script was interrupted; the remaining microtasks stay queued.
  bool drainMicrotasks({int maxMicrotasksHint = -1}) {
    if (!qjs_runtime_drain_microtasks(ptr, maxMicrotasksHint)) {
      throw JSException(getAndClearJSErrorValue());
    }
    return true;
  }

  JSValue getAndClearJSErrorValue() {
    return JSValue.fromABI(
      this,
      qjs_runtime_get_and_clear_js_error_value(ptr),
    );
  }

  String getAndClearNativeExceptionMessage() {
    final ptr = qjs_runtime_get_and_clear_native_exception_message(this.ptr);
    if (ptr == nullptr) return '';

    try {
      return ptr.cast<Utf8>().toDartString();
    } finally {
      // Allocated by the C runtime: package:ffi's malloc uses a different
      // heap on Windows.
      qjs_free(ptr.cast());
    }
  }

  Pointer<T> unwrapPtr<T extends NativeType>(int ptrOrError) {
    if ((ptrOrError & 1) != 0) {
      handleErrorCode(ptrOrError >> 2);
    }
    return Pointer.fromAddress(ptrOrError);
  }

  Pointer<QJSABIManagedPointer> unwrapManagedPtr(int ptrOrError) {
    return unwrapPtr<QJSABIManagedPointer>(ptrOrError);
  }

  bool unwrapBool(int boolOrError) {
    unwrapVoid(boolOrError);
    return (boolOrError >> 2) != 0;
  }

  void unwrapVoid(int ptrOrError) {
    if ((ptrOrError & 1) != 0) {
      handleErrorCode(ptrOrError >> 2);
    }
  }

  void handleErrorCode(int errorCode) {
    if (errorCode == QJSABIErrorCode.QJSABIErrorCodeNativeException.value) {
      throw JSNativeException(getAndClearNativeExceptionMessage());
    } else {
      throw JSException(getAndClearJSErrorValue());
    }
  }

  void setJSErrorValue(JSValue value) {
    qjs_runtime_set_js_error_value(ptr, value.ptr);
  }

  void setNativeExceptionMessage(String message) => using((arena) {
    final nativeMsg = message.toNativeUtf8(allocator: arena);
    qjs_runtime_set_native_exception_message(ptr, nativeMsg.cast());
  });

  /// Releases the runtime and all JS values it owns.
  ///
  /// Always call this when the runtime is no longer needed. The finalizer
  /// attached to the runtime is only a safety net: it is not guaranteed to
  /// run, and never runs if the isolate exits first, so a runtime that is
  /// not released explicitly may leak its whole JS heap.
  void release() {
    if (_released) return;
    _memoizedCache.clear();
    _importedModules.clear();
    _finalizer.detach(this);
    _runtimesRegistry.remove(_ptr.address);
    _released = true;
    qjs_runtime_release(_ptr);
  }
}

final _promiseRejectionTrackerCallable =
    NativeCallable<QJSABIPromiseRejectionTrackerFunction>.isolateLocal((
      Pointer<QJSABIRuntime> runtime,
      QJSABIValue promise,
      QJSABIValue reason,
      bool isHandled,
    ) {
      final rt = JSRuntime(runtime);
      // The native side passes owned references.
      final promiseValue = JSValue.fromABI(rt, promise);
      final reasonValue = JSValue.fromABI(rt, reason);
      final callback = rt._onUnhandledRejection;
      if (callback == null) return;
      try {
        callback(promiseValue, reasonValue, isHandled);
      } catch (error, stackTrace) {
        // Throwing here would unwind through QuickJS; report it as an
        // uncaught async error instead.
        scheduleMicrotask(() => Error.throwWithStackTrace(error, stackTrace));
      }
    });
