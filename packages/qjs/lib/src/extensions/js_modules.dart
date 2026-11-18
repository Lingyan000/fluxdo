import 'package:qjs/qjs.dart';

/// A [JSModuleLoader] serving host modules and virtual files.
///
/// ```dart
/// rt.moduleLoader = JSModules()
///   ..host('alloy', (rt) => {'version': .string(rt, '1.0.0')})
///   ..mount('/app', (path) => files[path])
///   ..alias('utils', '/app/lib/utils.js');
/// ```
///
/// Specifiers resolve like in browsers:
///
/// - paths starting with `/`, `./` or `../` resolve against the importing
///   module, and never above `/`. Scripts and [JSRuntime.importModule]
///   resolve them against `/`;
/// - other (bare) specifiers are looked up in [alias]es, then in [host]
///   modules.
///
/// A path loads from the [mount] with the longest matching prefix. Paths are
/// exact: no extension or `index.js` is added. Like in browsers, a file is
/// parsed as JSON only when imported `with { type: 'json' }`.
///
/// Modules can be added after imports have started, but a module that was
/// already imported stays cached by the runtime.
class JSModules implements JSModuleLoader {
  final Map<String, Map<String, JSValue> Function(JSRuntime rt)> _hosts = {};
  final Map<String, String> _aliases = {};
  final Map<String, String? Function(String path)> _mounts = {};
  // The last importer of each path, for error messages.
  final Map<String, String> _referrers = {};

  /// Serves the module [name], exporting the values [exports] builds the
  /// first time it is imported.
  ///
  /// ```dart
  /// modules.host('alloy', (rt) => {
  ///   'createWindow': JSFunction.createFromHostFunction(rt, ...).asValue,
  /// });
  /// ```
  void host(
    String name,
    Map<String, JSValue> Function(JSRuntime rt) exports,
  ) {
    _checkBare(name, 'name');
    if (_aliases.containsKey(name)) {
      throw ArgumentError.value(name, 'name', 'is already an alias');
    }
    _hosts[name] = exports;
  }

  /// Makes the bare [specifier] import [target]: an absolute path or a
  /// [host] module.
  ///
  /// A [specifier] ending with `/` maps every specifier it prefixes, and its
  /// [target] must be a path ending with `/`:
  ///
  /// ```dart
  /// modules.alias('@ui/', '/app/ui/'); // '@ui/button.js' → '/app/ui/button.js'
  /// ```
  void alias(String specifier, String target) {
    _checkBare(specifier, 'specifier');
    if (_hosts.containsKey(specifier)) {
      throw ArgumentError.value(specifier, 'specifier', 'is a host module');
    }
    if (_isRelative(target)) {
      throw ArgumentError.value(target, 'target', 'must not be relative');
    }
    if (specifier.endsWith('/') &&
        !(target.startsWith('/') && target.endsWith('/'))) {
      throw ArgumentError.value(
        target,
        'target',
        "must be a path ending with '/' for a prefix alias",
      );
    }
    _aliases[specifier] = target;
  }

  /// Serves the paths under [prefix] from [read], which receives the path
  /// relative to [prefix] and returns the file's contents, or null if there
  /// is no such file.
  ///
  /// ```dart
  /// modules.mount('/app', (path) => files[path]); // '/app/lib/a.js' → 'lib/a.js'
  /// ```
  void mount(String prefix, String? Function(String path) read) {
    if (!prefix.startsWith('/')) {
      throw ArgumentError.value(prefix, 'prefix', "must start with '/'");
    }
    _mounts[_normalize(prefix, '/')] = read;
  }

  @override
  String resolve(JSRuntime rt, String specifier, String referrer) {
    if (_isPath(specifier)) {
      final name = _normalize(specifier, referrer);
      _referrers[name] = referrer;
      return name;
    }

    final target = _resolveAlias(specifier);
    if (target != null) {
      if (!target.startsWith('/')) return _resolveHost(rt, target, referrer);
      final name = _normalize(target, '/');
      _referrers[name] = referrer;
      return name;
    }
    return _resolveHost(rt, specifier, referrer);
  }

  @override
  JSModuleSource load(JSRuntime rt, String name, JSImportType type) {
    final exports = _hosts[name];
    if (exports != null) {
      if (type != .javascript) {
        throw JSException(
          JSError.typeError(
            rt,
            "Host module '$name' cannot be imported as ${type.name}",
          ),
        );
      }
      return .exports(exports(rt));
    }

    final source = _read(name);
    if (source == null) throw _notFound(rt, name, _referrers[name] ?? '');

    return switch (type) {
      .javascript => .code(source),
      .json => .json(source),
      .text => .text(source),
    };
  }

  String? _resolveAlias(String specifier) {
    final exact = _aliases[specifier];
    if (exact != null && !specifier.endsWith('/')) return exact;

    String? longest;
    for (final key in _aliases.keys) {
      if (key.endsWith('/') &&
          specifier.startsWith(key) &&
          key.length > (longest?.length ?? 0)) {
        longest = key;
      }
    }
    if (longest == null) return null;
    return _aliases[longest]! + specifier.substring(longest.length);
  }

  String _resolveHost(JSRuntime rt, String name, String referrer) {
    if (_hosts.containsKey(name)) return name;
    throw _notFound(rt, name, referrer);
  }

  String? _read(String name) {
    String? prefix;
    for (final key in _mounts.keys) {
      final matches = key == '/' || name.startsWith('$key/');
      if (matches && key.length > (prefix?.length ?? 0)) prefix = key;
    }
    if (prefix == null) return null;
    final path = name.substring(prefix == '/' ? 1 : prefix.length + 1);
    return _mounts[prefix]!(path);
  }

  static JSException _notFound(JSRuntime rt, String name, String referrer) {
    final from = referrer.isEmpty ? '' : " imported from '$referrer'";
    return JSException(
      JSError.referenceError(rt, "Cannot find module '$name'$from"),
    );
  }

  static bool _isRelative(String specifier) =>
      specifier.startsWith('./') || specifier.startsWith('../');

  static bool _isPath(String specifier) =>
      specifier.startsWith('/') || _isRelative(specifier);

  static void _checkBare(String name, String argument) {
    if (name.isEmpty || _isPath(name)) {
      throw ArgumentError.value(name, argument, 'must be a bare specifier');
    }
  }

  // Resolves [path] against [base], dropping `.`, `..` and empty segments.
  // A [base] that is not absolute, like a script's name, counts as `/`.
  static String _normalize(String path, String base) {
    final segments = <String>[];
    if (!path.startsWith('/') && base.startsWith('/')) {
      segments.addAll(base.split('/').skip(1));
      segments.removeLast();
    }
    for (final segment in path.split('/')) {
      if (segment == '..') {
        if (segments.isNotEmpty) segments.removeLast();
      } else if (segment.isNotEmpty && segment != '.') {
        segments.add(segment);
      }
    }
    return '/${segments.join('/')}';
  }
}
