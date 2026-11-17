import 'dart:ffi';

import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_value.dart';

/// Called when a promise is rejected without a handler ([isHandled] is
/// false), and again if a handler is attached later ([isHandled] is true).
///
/// Runs synchronously on the runtime's isolate while JavaScript executes.
typedef JSUnhandledRejectionCallback = void Function(
  JSValue promise,
  JSValue reason,
  bool isHandled,
);

/// A sendable handle that interrupts a runtime's JavaScript execution.
///
/// Unlike the runtime itself, the handle can be sent to another isolate, for
/// example to a supervisor that cancels a long-running script while the
/// runtime's isolate is blocked in it.
final class JSInterruptHandle {
  @internal
  const JSInterruptHandle(this._address, this._id);

  final int _address;
  final int _id;

  /// Interrupts the running JavaScript execution, or the next one if none is
  /// running. The interrupted code throws an uncatchable
  /// `InternalError: interrupted`, which surfaces as a `JSException`.
  ///
  /// Returns false if the runtime has already been released.
  bool requestInterrupt() =>
      qjs_runtime_request_interrupt(Pointer.fromAddress(_address), _id);
}

/// A snapshot of a runtime's memory usage, in bytes and object counts.
final class JSMemoryUsage {
  @internal
  JSMemoryUsage.fromABI(QJSABIMemoryUsage usage)
    : mallocSize = usage.malloc_size,
      mallocLimit = usage.malloc_limit,
      memoryUsedSize = usage.memory_used_size,
      mallocCount = usage.malloc_count,
      memoryUsedCount = usage.memory_used_count,
      atomCount = usage.atom_count,
      atomSize = usage.atom_size,
      stringCount = usage.str_count,
      stringSize = usage.str_size,
      objectCount = usage.obj_count,
      objectSize = usage.obj_size,
      propertyCount = usage.prop_count,
      propertySize = usage.prop_size,
      shapeCount = usage.shape_count,
      shapeSize = usage.shape_size,
      jsFunctionCount = usage.js_func_count,
      jsFunctionSize = usage.js_func_size,
      jsFunctionCodeSize = usage.js_func_code_size,
      cFunctionCount = usage.c_func_count,
      arrayCount = usage.array_count,
      fastArrayCount = usage.fast_array_count,
      fastArrayElements = usage.fast_array_elements,
      binaryObjectCount = usage.binary_object_count,
      binaryObjectSize = usage.binary_object_size;

  /// Bytes currently allocated by the runtime.
  final int mallocSize;

  /// The configured memory limit, or -1 if there is none.
  final int mallocLimit;

  /// Bytes used by JS data, including allocator overhead estimates.
  final int memoryUsedSize;

  final int mallocCount;
  final int memoryUsedCount;
  final int atomCount;
  final int atomSize;
  final int stringCount;
  final int stringSize;
  final int objectCount;
  final int objectSize;
  final int propertyCount;
  final int propertySize;
  final int shapeCount;
  final int shapeSize;
  final int jsFunctionCount;
  final int jsFunctionSize;
  final int jsFunctionCodeSize;
  final int cFunctionCount;
  final int arrayCount;
  final int fastArrayCount;
  final int fastArrayElements;
  final int binaryObjectCount;
  final int binaryObjectSize;

  @override
  String toString() =>
      'JSMemoryUsage(mallocSize: $mallocSize, mallocLimit: $mallocLimit, '
      'memoryUsedSize: $memoryUsedSize, objectCount: $objectCount)';
}
