import 'package:qjs/src/js_runtime.dart';

/// Configuration options for creating a [JSRuntime].
class JSRuntimeConfig {
  /// Creates a runtime configuration.
  ///
  /// [memoryLimit] sets the maximum allocated memory in bytes
  /// (0 = unlimited).
  /// [maxStackSize] sets the maximum system stack size in bytes
  /// (0 = default).
  /// [gcThreshold] sets the memory threshold in bytes to trigger GC
  /// (0 = default).
  const JSRuntimeConfig({
    this.enableEval = true,
    this.es6Proxy = true,
    this.microtaskQueue = false,
    this.memoryLimit = 0,
    this.maxStackSize = 0,
    this.gcThreshold = 0,
  });

  /// Creates a hardened configuration suitable for sandboxed,
  /// restricted execution.
  ///
  /// Disables `eval` and `Proxy`, and restricts memory to 64 MB
  /// and stack to 512 KB.
  const JSRuntimeConfig.hardened({
    this.memoryLimit = 64 * 1024 * 1024,
    this.maxStackSize = 512 * 1024,
    this.gcThreshold = 0,
  })  : enableEval = false,
        es6Proxy = false,
        microtaskQueue = false;

  /// Whether to allow dynamic code evaluation via `eval` and `new Function`.
  final bool enableEval;

  /// Whether ES6 `Proxy` is available in the global scope.
  final bool es6Proxy;

  /// Whether to manage an explicit microtask queue for Promises.
  final bool microtaskQueue;

  /// Maximum heap memory in bytes allocated by the runtime (0 = unlimited).
  final int memoryLimit;

  /// Maximum stack size in bytes allocated for execution (0 = default).
  final int maxStackSize;

  /// Memory allocation threshold in bytes before automatic GC runs
  /// (0 = default).
  final int gcThreshold;
}
