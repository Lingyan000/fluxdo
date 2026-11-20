import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_runtime.dart';
import 'package:qjs/src/js_value.dart';

/// How a module is imported, from the `type` import attribute:
///
/// ```js
/// import config from './config.json' with { type: 'json' };
/// ```
enum JSImportType { javascript, json, text }

/// The contents of a module returned by [JSModuleLoader.load].
sealed class JSModuleSource {
  const JSModuleSource();

  /// A JavaScript module compiled from [source].
  const factory JSModuleSource.code(String source) = _CodeModuleSource;

  /// A module whose default export is [source] parsed as JSON.
  const factory JSModuleSource.json(String source) = _JsonModuleSource;

  /// A module whose default export is the string [source].
  const factory JSModuleSource.text(String source) = _TextModuleSource;

  /// A module exporting [exports] by name, built by the host.
  const factory JSModuleSource.exports(Map<String, JSValue> exports) =
      _ExportsModuleSource;

  JSValue _toJSValue(JSRuntime rt);
}

final class _CodeModuleSource extends JSModuleSource {
  const _CodeModuleSource(this.source);

  final String source;

  @override
  JSValue _toJSValue(JSRuntime rt) => .string(rt, source);
}

final class _JsonModuleSource extends JSModuleSource {
  const _JsonModuleSource(this.source);

  final String source;

  @override
  JSValue _toJSValue(JSRuntime rt) => (JSObject.create(
    rt,
  )..['default'] = .fromJsonUtf8(rt, utf8.encode(source))).asValue;
}

final class _TextModuleSource extends JSModuleSource {
  const _TextModuleSource(this.source);

  final String source;

  @override
  JSValue _toJSValue(JSRuntime rt) =>
      (JSObject.create(rt)..['default'] = .string(rt, source)).asValue;
}

final class _ExportsModuleSource extends JSModuleSource {
  const _ExportsModuleSource(this.exports);

  final Map<String, JSValue> exports;

  @override
  JSValue _toJSValue(JSRuntime rt) {
    final obj = JSObject.create(rt);
    for (final MapEntry(:key, :value) in exports.entries) {
      obj[key] = value;
    }
    return obj.asValue;
  }
}

/// Resolves and loads the modules imported by JavaScript code.
///
/// Set it as [JSRuntime.moduleLoader]. Both methods are synchronous, since
/// QuickJS resolves imports while it compiles a module. They must not
/// evaluate modules themselves.
///
/// Throwing a [JSException] from either method makes the import fail with
/// its value; any other error fails it with an `Error` carrying its message.
abstract class JSModuleLoader {
  /// The canonical name of [specifier] imported from [referrer], which is
  /// the canonical name of the importing module, the `sourceUrl` of the
  /// importing script, or an empty string for [JSRuntime.importModule].
  ///
  /// The runtime caches modules by canonical name.
  String resolve(JSRuntime rt, String specifier, String referrer);

  /// The module with the canonical [name], imported as [type].
  ///
  /// Called once per name and type: later imports reuse the module.
  JSModuleSource load(JSRuntime rt, String name, JSImportType type);
}

@internal
QJSABIModuleResolve get moduleResolveFunction =>
    _moduleResolveCallable.nativeFunction;

@internal
QJSABIModuleLoad get moduleLoadFunction => _moduleLoadCallable.nativeFunction;

final _moduleResolveCallable =
    NativeCallable<QJSABIModuleResolveFunction>.isolateLocal((
      Pointer<QJSABIRuntime> runtime,
      Pointer<Char> specifier,
      Pointer<Char> referrer,
    ) {
      final rt = JSRuntime(runtime);
      return _callLoader(
        rt,
        () => JSValue.string(
          rt,
          rt.moduleLoader!.resolve(
            rt,
            specifier.cast<Utf8>().toDartString(),
            referrer.cast<Utf8>().toDartString(),
          ),
        ),
      );
    })..keepIsolateAlive = false;

final _moduleLoadCallable =
    NativeCallable<QJSABIModuleLoadFunction>.isolateLocal((
      Pointer<QJSABIRuntime> runtime,
      Pointer<Char> name,
      int type,
    ) {
      final rt = JSRuntime(runtime);
      return _callLoader(
        rt,
        () => rt.moduleLoader!
            .load(
              rt,
              name.cast<Utf8>().toDartString(),
              JSImportType.values[type],
            )
            ._toJSValue(rt),
      );
    })..keepIsolateAlive = false;

QJSABIValueOrError _callLoader(JSRuntime rt, JSValue Function() fn) {
  rt.moduleLoaderDepth++;
  try {
    // The native side releases the returned value, so hand it its own
    // reference (see the host function callback in js_function.dart).
    final retained = fn().retain();
    retained.jsPointer?.detachFinalizer();
    return Struct.create<QJSABIValueOrError>()..value = retained.ptr;
  } on JSException catch (error) {
    rt.setJSErrorValue(error.value);
    return Struct.create<QJSABIValueOrError>()
      ..value.kind = .QJSABIValueKindError
      ..value.data.error = .QJSABIErrorCodeJSError;
  } catch (error) {
    rt.setNativeExceptionMessage(
      error is JSNativeException ? error.message : error.toString(),
    );
    return Struct.create<QJSABIValueOrError>()
      ..value.kind = .QJSABIValueKindError
      ..value.data.error = .QJSABIErrorCodeNativeException;
  } finally {
    rt.moduleLoaderDepth--;
  }
}
