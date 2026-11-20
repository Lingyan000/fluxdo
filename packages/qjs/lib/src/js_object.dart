import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_array.dart';
import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_function.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_prop_id.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

/// A base class for exposing Dart objects to JavaScript.
///
/// Example:
/// ```dart
/// class Counter extends JSHostObject {
///   int count = 0;
///
///   @override
///   JSValue get(JSRuntime rt, JSPropNameId name) {
///     return switch (name.string) {
///       'count' => JSValue.number(rt, count.toDouble()),
///       _ => JSValue.undefined(rt),
///     };
///   }
///
///   @override
///   void set(JSRuntime rt, JSPropNameId name, JSValue value) {
///     if (name.string == 'count') {
///       if (!value.isNumber) {
///         throw JSNativeException('count must be a number');
///       }
///       count = value.asNumber.toInt();
///     }
///   }
///
///   @override
///   List<JSPropNameId> getPropertyNames(JSRuntime rt) => [
///     JSPropNameId.fromString(rt, 'count'),
///   ];
/// }
/// ```
abstract class JSHostObject {
  /// Called when JavaScript reads a property.
  JSValue get(JSRuntime rt, JSPropNameId name);

  /// Called when JavaScript writes a property.
  void set(JSRuntime rt, JSPropNameId name, JSValue value);

  /// Returns keys visible to `Object.keys()` or `for...in`.
  List<JSPropNameId> getPropertyNames(JSRuntime rt) => [];

  /// Whether the object owns the property [name], for `in`, `hasOwnProperty`
  /// and enumeration.
  ///
  /// Defaults to looking [name] up in [getPropertyNames]. Override it when
  /// that list is expensive to build: enumerating the object asks this once
  /// per key.
  bool has(JSRuntime rt, JSPropNameId name) =>
      getPropertyNames(rt).any((key) => key.equals(name));

  /// Called when the object is garbage collected or the runtime is released.
  void release() {}
}

final Map<int, JSHostObject> _hostObjectsRegistry = {};
int _nextHostObjectId = 1;

final Map<int, Object> _nativeStateRegistry = {};
int _nextNativeStateId = 1;

/// Represents a JavaScript `Object`.
///
/// Example:
/// ```dart
/// final obj = JSObject.create(rt);
/// obj['key'] = JSValue.string(rt, 'value');
/// print(obj['key'].asDartString); // 'value'
/// ```
extension type JSObject(JSPointer jsPointer) implements Finalizable {
  /// Creates a new empty object.
  factory JSObject.create(JSRuntime rt) {
    final result = qjs_object_create(rt.ptr);
    return JSObject(JSPointer(rt, rt.unwrapManagedPtr(result.ptr_or_error)));
  }

  /// Creates an object backed by a Dart [object].
  factory JSObject.createFromHostObject(JSRuntime rt, JSHostObject object) {
    final id = _nextHostObjectId++;
    _hostObjectsRegistry[id] = object;

    final result = qjs_object_create_from_host_object(
      rt.ptr,
      Pointer.fromAddress(id),
      _hostObjectGetCallable.nativeFunction,
      _hostObjectSetCallable.nativeFunction,
      _hostObjectGetOwnKeysCallable.nativeFunction,
      _hostObjectHasCallable.nativeFunction,
      _hostObjectReleaseCallable.nativeFunction,
    );

    return JSObject(JSPointer(rt, rt.unwrapManagedPtr(result.ptr_or_error)));
  }

  /// Returns a JSObject associated with a given unique ID, or null.
  static JSObject? fromId(JSRuntime rt, int id) {
    final result = qjs_object_from_id(rt.ptr, id);
    final val = JSValue.fromABI(rt, result.value);
    if (val.isNull || val.isUndefined) {
      return null;
    }
    return val.asObject;
  }

  QJSABIObject get ptr => jsPointer.asObject;

  JSRuntime get _rt => jsPointer.rt;

  /// Returns true if this object is a function.
  bool get isFunction => qjs_object_is_function(_rt.ptr, ptr);

  /// Returns this object as a [JSFunction].
  JSFunction get asFunction => JSFunction(jsPointer);

  JSValue get asValue => JSValue.fromObject(this);

  JSValue getProperty(String name) {
    final keyVal = JSValue.string(_rt, name, attachFinalizer: false);
    try {
      final result = qjs_object_get_property_from_value(
        _rt.ptr,
        ptr,
        keyVal.ptr,
      );
      return JSValue.fromABI(_rt, result);
    } finally {
      keyVal.release();
    }
  }

  void setProperty(String name, JSValue value) {
    final keyVal = JSValue.string(_rt, name, attachFinalizer: false);
    try {
      final result = qjs_object_set_property_from_value(
        _rt.ptr,
        ptr,
        keyVal.ptr,
        value.ptr,
      );
      _rt.unwrapVoid(result.void_or_error);
    } finally {
      keyVal.release();
    }
  }

  bool hasProperty(String name) {
    final keyVal = JSValue.string(_rt, name, attachFinalizer: false);
    try {
      final result = qjs_object_has_property_from_value(
        _rt.ptr,
        ptr,
        keyVal.ptr,
      );
      return _rt.unwrapBool(result.bool_or_error);
    } finally {
      keyVal.release();
    }
  }

  JSValue getPropertyFromPropNameId(JSPropNameId id) {
    final result = qjs_object_get_property_from_propnameid(
      _rt.ptr,
      ptr,
      id.ptr,
    );

    return JSValue.fromABI(_rt, result);
  }

  void setPropertyFromPropNameId(JSPropNameId id, JSValue value) {
    final result = qjs_object_set_property_from_propnameid(
      _rt.ptr,
      ptr,
      id.ptr,
      value.ptr,
    );

    _rt.unwrapVoid(result.void_or_error);
  }

  bool hasPropertyFromPropNameId(JSPropNameId id) {
    final result = qjs_object_has_property_from_propnameid(
      _rt.ptr,
      ptr,
      id.ptr,
    );

    return _rt.unwrapBool(result.bool_or_error);
  }

  JSArray getPropertyNames() {
    final result = qjs_object_get_property_names(_rt.ptr, ptr);
    return JSArray(JSPointer(_rt, _rt.unwrapManagedPtr(result.ptr_or_error)));
  }

  JSValue operator [](String key) => getProperty(key);

  void operator []=(String key, JSValue value) => setProperty(key, value);

  bool strictEquals(JSObject other) {
    return jsPointer.strictEquals(other.jsPointer);
  }

  /// Returns true if this object is an instance of the given [constructor].
  bool instanceOf(JSFunction constructor) {
    final result = qjs_instance_of(_rt.ptr, ptr, constructor.ptr);
    return _rt.unwrapBool(result.bool_or_error);
  }

  /// Defines a property on this object (Object.defineProperty).
  ///
  /// Example (data descriptor):
  /// ```dart
  /// obj.defineProperty(
  ///   'version',
  ///   value: JSValue.string(rt, '1.0.0'),
  ///   writable: false,
  /// );
  /// ```
  ///
  /// Example (accessor descriptor):
  /// ```dart
  /// obj.defineProperty(
  ///   'now',
  ///   get: JSFunction.createFromHostFunction(rt, (rt, _, __) {
  ///     final ms = DateTime.now().millisecondsSinceEpoch.toDouble();
  ///     return JSValue.number(rt, ms);
  ///   }),
  /// );
  /// ```
  void defineProperty(
    String propertyName, {
    JSValue? value,
    bool? writable,
    bool? enumerable,
    bool? configurable,
    JSFunction? get,
    JSFunction? set,
  }) {
    final hasAccessors = get != null || set != null;
    final hasData = value != null || writable != null;

    assert(
      !(hasAccessors && hasData),
      'TypeError: Invalid property descriptor. '
      'Cannot both specify accessors and a value or writable attribute.',
    );

    final definePropertyFn = _rt.memoize(
      'Object.defineProperty',
      () => _rt.global['Object'].asObject['defineProperty'].asFunctionUnsafe,
    );

    final descriptor = JSObject.create(_rt);

    if (value != null) descriptor['value'] = value;
    if (writable != null) {
      descriptor['writable'] = JSValue.boolean(_rt, writable);
    }
    if (enumerable != null) {
      descriptor['enumerable'] = JSValue.boolean(_rt, enumerable);
    }
    if (configurable != null) {
      descriptor['configurable'] = JSValue.boolean(_rt, configurable);
    }

    if (get != null) descriptor['get'] = JSValue.fromObject(get.asObject);
    if (set != null) descriptor['set'] = JSValue.fromObject(set.asObject);

    definePropertyFn([
      .fromObject(this),
      .string(_rt, propertyName),
      .fromObject(descriptor),
    ]);
  }

  /// Prevents new properties from being added to the object.
  void preventExtensions() {
    final fn = _rt.memoize(
      'Object.preventExtensions',
      () => _rt.global['Object'].asObject['preventExtensions'].asFunctionUnsafe,
    );
    fn([JSValue.fromObject(this)]);
  }

  /// Prevents adding or removing properties.
  void seal() {
    final fn = _rt.memoize(
      'Object.seal',
      () => _rt.global['Object'].asObject['seal'].asFunctionUnsafe,
    );
    fn([JSValue.fromObject(this)]);
  }

  /// Prevents any changes to the object (makes it immutable).
  void freeze() {
    final fn = _rt.memoize(
      'Object.freeze',
      () => _rt.global['Object'].asObject['freeze'].asFunctionUnsafe,
    );
    fn([JSValue.fromObject(this)]);
  }

  /// Sets the prototype of the object.
  void setPrototypeOf(JSValue prototype) {
    final fn = _rt.memoize(
      'Object.setPrototypeOf',
      () => _rt.global['Object'].asObject['setPrototypeOf'].asFunctionUnsafe,
    );
    fn([JSValue.fromObject(this), prototype]);
  }

  /// Returns the prototype of the object.
  JSValue getPrototypeOf() {
    final fn = _rt.memoize(
      'Object.getPrototypeOf',
      () => _rt.global['Object'].asObject['getPrototypeOf'].asFunctionUnsafe,
    );
    return fn([JSValue.fromObject(this)]);
  }

  /// Associates arbitrary Dart [state] with this object.
  void setNativeState(Object state) {
    final id = _nextNativeStateId++;
    _nativeStateRegistry[id] = state;

    final result = qjs_object_set_native_state(
      _rt.ptr,
      ptr,
      Pointer.fromAddress(id),
      _nativeStateReleaseCallable.nativeFunction,
    );

    _rt.unwrapVoid(result.void_or_error);
  }

  /// Returns the Dart state associated with this object.
  Object? getNativeState() {
    final dataPtr = qjs_object_get_native_state_data(_rt.ptr, ptr);
    if (dataPtr == nullptr) return null;

    return _nativeStateRegistry[dataPtr.address];
  }

  /// Increments the native reference count and returns a new handle to the
  /// same JSObject.
  JSObject retain() {
    return JSObject(jsPointer.clone());
  }
}

extension JSPointerObjectExt on JSPointer {
  QJSABIObject get asObject => Struct.create()..pointer = handle;
}

final _nativeStateReleaseCallable =
    NativeCallable<QJSABINativeStateReleaseFunction>.listener(
      (Pointer<Void> userData) {
        _nativeStateRegistry.remove(userData.address);
      },
    )..keepIsolateAlive = false;

final _hostObjectReleaseCallable =
    NativeCallable<QJSABIHostObjectReleaseFunction>.listener(
      (Pointer<Void> userData) {
        final object = _hostObjectsRegistry.remove(userData.address);
        object?.release();
      },
    )..keepIsolateAlive = false;

final _hostObjectGetCallable =
    NativeCallable<QJSABIHostObjectGetFunction>.isolateLocal((
      Pointer<Void> userData,
      Pointer<QJSABIRuntime> runtime,
      QJSABIPropNameID name,
    ) {
      final rt = JSRuntime(runtime);
      final object = _hostObjectsRegistry[userData.address]!;

      try {
        final result = object.get(
          rt,
          JSPropNameId.fromABI(rt, name, attachFinalizer: false),
        );

        // Retain and detach the finalizer because ownership is transferred to
        // the C++ caller. See the detailed explanation in js_function.dart.
        final retained = result.retain();
        retained.jsPointer?.detachFinalizer();

        return Struct.create<QJSABIValueOrError>()..value = retained.ptr;
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

final _hostObjectSetCallable =
    NativeCallable<QJSABIHostObjectSetFunction>.isolateLocal((
      Pointer<Void> userData,
      Pointer<QJSABIRuntime> runtime,
      QJSABIPropNameID name,
      Pointer<QJSABIValue> value,
    ) {
      final rt = JSRuntime(runtime);
      final object = _hostObjectsRegistry[userData.address]!;

      try {
        object.set(
          rt,
          JSPropNameId.fromABI(rt, name, attachFinalizer: false),
          JSValue.fromABI(rt, value.ref, attachFinalizer: false),
        );

        return Struct.create<QJSABIVoidOrError>()..void_or_error = 0;
      } on JSException catch (error) {
        rt.setJSErrorValue(error.value);
        return Struct.create<QJSABIVoidOrError>()
          ..void_or_error =
              (QJSABIErrorCode.QJSABIErrorCodeJSError.value << 2) | 1;
      } on JSNativeException catch (error) {
        rt.setNativeExceptionMessage(error.message);
        return Struct.create<QJSABIVoidOrError>()
          ..void_or_error =
              (QJSABIErrorCode.QJSABIErrorCodeNativeException.value << 2) | 1;
      } catch (error) {
        rt.setNativeExceptionMessage(error.toString());
        return Struct.create<QJSABIVoidOrError>()
          ..void_or_error =
              (QJSABIErrorCode.QJSABIErrorCodeNativeException.value << 2) | 1;
      }
    })..keepIsolateAlive = false;

final _hostObjectGetOwnKeysCallable =
    NativeCallable<QJSABIHostObjectGetOwnKeysFunction>.isolateLocal((
      Pointer<Void> userData,
      Pointer<QJSABIRuntime> runtime,
    ) {
      final rt = JSRuntime(runtime);
      final object = _hostObjectsRegistry[userData.address]!;

      try {
        final keys = object.getPropertyNames(rt);
        final props = calloc<QJSABIPropNameID>(keys.length);

        for (var i = 0; i < keys.length; i++) {
          props[i] = keys[i].ptr;
        }

        final list = qjs_propnameid_list_create(props, keys.length);
        calloc.free(props);

        return Struct.create<QJSABIPropNameIDListPtrOrError>()
          ..ptr_or_error = list.address;
      } on JSException catch (error) {
        rt.setJSErrorValue(error.value);
        return Struct.create<QJSABIPropNameIDListPtrOrError>()
          ..ptr_or_error =
              (QJSABIErrorCode.QJSABIErrorCodeJSError.value << 2) | 1;
      } on JSNativeException catch (error) {
        rt.setNativeExceptionMessage(error.message);
        return Struct.create<QJSABIPropNameIDListPtrOrError>()
          ..ptr_or_error =
              (QJSABIErrorCode.QJSABIErrorCodeNativeException.value << 2) | 1;
      } catch (e) {
        rt.setNativeExceptionMessage(e.toString());
        return Struct.create<QJSABIPropNameIDListPtrOrError>()
          ..ptr_or_error =
              (QJSABIErrorCode.QJSABIErrorCodeNativeException.value << 2) | 1;
      }
    })..keepIsolateAlive = false;

final _hostObjectHasCallable =
    NativeCallable<QJSABIHostObjectHasFunction>.isolateLocal((
      Pointer<Void> userData,
      Pointer<QJSABIRuntime> runtime,
      QJSABIPropNameID name,
    ) {
      final rt = JSRuntime(runtime);
      final object = _hostObjectsRegistry[userData.address]!;

      int error(QJSABIErrorCode code) => (code.value << 2) | 1;
      try {
        final found = object.has(
          rt,
          JSPropNameId.fromABI(rt, name, attachFinalizer: false),
        );
        return Struct.create<QJSABIBoolOrError>()
          ..bool_or_error = found ? 4 : 0;
      } on JSException catch (e) {
        rt.setJSErrorValue(e.value);
        return Struct.create<QJSABIBoolOrError>()
          ..bool_or_error = error(.QJSABIErrorCodeJSError);
      } on JSNativeException catch (e) {
        rt.setNativeExceptionMessage(e.message);
        return Struct.create<QJSABIBoolOrError>()
          ..bool_or_error = error(.QJSABIErrorCodeNativeException);
      } catch (e) {
        rt.setNativeExceptionMessage(e.toString());
        return Struct.create<QJSABIBoolOrError>()
          ..bool_or_error = error(.QJSABIErrorCodeNativeException);
      }
    });
