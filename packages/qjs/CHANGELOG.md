## 0.2.3

### Fixes

- Prebuilt binaries are cached per target. An iOS build no longer bundles a binary downloaded for macOS.

## 0.2.2

### Features

- ES modules:
  - `JSRuntime.importModule` / `evaluateModule` import and evaluate modules and wait for their top-level `await`. `importModuleSync` / `evaluateModuleSync` return right away.
  - `JSRuntime.moduleLoader` resolves and loads the modules JavaScript imports, including through `import()`. Imports stay disabled until it is set.
  - `JSModules` serves host modules built from Dart values (`host`), files from a virtual file system (`mount`) and import-map-like aliases (`alias`).
  - `with { type: 'json' }` and `with { type: 'text' }` import attributes are supported.

## 0.2.1

### Fixes

- Using a `JSRuntime` after `release()` now throws a `StateError` instead of crashing the process. This includes a `JSPromise.fromAsyncFunction` callback that builds its result after the runtime was released while it was awaiting.
- Updated the code examples in the API docs to the current API.

## 0.2.0

### Breaking changes

- With `enableEval: false` (including `JSRuntimeConfig.hardened()`), the `Function`, `AsyncFunction`, `GeneratorFunction` and `AsyncGeneratorFunction` constructors now throw. Previously, code could still be compiled through them.
- A microtask that fails while draining (for example, because the script was interrupted) is now reported instead of dropped. `evaluateJavascript`, `evaluatePreparedJavaScript` and function calls throw a `JSException`, and `drainMicrotasks()` throws instead of returning `false`.
- Errors thrown by `setTimeout` / `setInterval` callbacks installed by `JSTimers` no longer surface as uncaught Dart errors. They go to `JSRuntime.onUncaughtError`, and are dropped if it is not set.
- Calling `setNativeState` again on the same object now replaces the state. Previously the second call was silently ignored.
- `JSRuntime` uses a Dart `Finalizer` instead of a `NativeFinalizer`. Releasing a runtime that is never released explicitly is best effort; always call `release()`.

### Features

- Sandbox controls on `JSRuntime`:
  - `setDeadline` / `clearDeadline` interrupt long-running scripts with an uncatchable `InternalError: interrupted`.
  - `requestInterrupt` and the sendable `interruptHandle` cancel a script from another isolate.
  - `memoryUsage` reports heap usage as a `JSMemoryUsage`.
  - `onUnhandledRejection` tracks promises rejected without a handler.
  - `onUncaughtError` receives errors from JavaScript that runs with no Dart caller.
  - `runGC` runs the garbage collector.
- `JSHostObject.has` answers `in` and per-key checks without rebuilding the key list.
- Updated QuickJS-ng to v0.17.0.

### Fixes

- Fixed a deadlock between `JSRuntime.release()` and pointer finalizers running during GC, and a use-after-free on the runtime in those finalizers.
- Fixed a crash (double free) when JavaScript used `in`, `Object.keys` or `for...in` on a host object.
- `Object.keys`, `for...in`, `JSON.stringify` and `hasOwnProperty` now see host object keys.
- Fixed `JSValue.fromJsonUtf8` intermittently failing on valid JSON.
- JavaScript errors are no longer lost in array element reads, key conversion, property name listing and object creation.
- `getNativeState` no longer returns state inherited from a prototype, and native state is no longer visible to JavaScript.
- `JSArray.create` accepts lengths up to 2³² − 1 and throws a `RangeError` above that, instead of truncating the length.
- Fixed a race in `JSObject.fromId` with finalizers running during GC.
- Strings returned by the native library are freed with the library's own allocator, which matters on Windows.
- Handled native allocation failures that previously crashed or leaked.

## 0.1.0

- Initial version.
