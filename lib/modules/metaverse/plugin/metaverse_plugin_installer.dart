import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, AssetManifest;
import 'package:rfw/formats.dart';

import 'metaverse_plugin_manifest.dart';
import 'metaverse_plugin_network.dart';
import 'metaverse_plugin_store.dart';
import 'package:fluxdo_plugin_runtime/fluxdo_plugin_runtime.dart';

/// 下载并校验完毕、等待用户确认的插件包。
@immutable
class MetaversePluginPackage {
  const MetaversePluginPackage({
    required this.manifest,
    required this.source,
    required this.code,
  });

  final MetaversePluginManifest manifest;
  final String source;
  final MetaversePluginCode code;

  /// 只提示同一来源的较新版本，防止随应用回退时降级已安装插件。
  bool isUpdateFor(InstalledMetaversePlugin installed) {
    if (manifest.id != installed.id || source != installed.source) return false;
    return PluginVersion.parse(manifest.version).compareTo(
      PluginVersion.parse(installed.manifest.version),
    ) > 0;
  }
}

class MetaversePluginInstallException implements Exception {
  const MetaversePluginInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从清单地址取回插件包并做安装前校验。
///
/// 这里只下载和校验，不落盘：用户在权限确认页同意后才由调用方写入。
class MetaversePluginInstaller {
  MetaversePluginInstaller({
    required this._network,
    this.reservedHosts = const [],
  });

  static const maxManifestBytes = 32 * 1024;
  static const maxUiBytes = 256 * 1024;
  static const maxScriptBytes = 512 * 1024;

  final MetaversePluginNetwork _network;
  final List<String> reservedHosts;

  /// 随客户端分发的插件也经过同一套安装校验，只有用户确认后才会写入。
  Future<List<MetaversePluginPackage>> bundledPackages(
    AssetBundle assets,
  ) async {
    final index = await AssetManifest.loadFromAssetBundle(assets);
    final paths =
        index
            .listAssets()
            .where(
              (key) =>
                  key.startsWith('plugins/') && key.endsWith('/plugin.json'),
            )
            .toList()
          ..sort();
    final packages = <MetaversePluginPackage>[];
    for (final path in paths) {
      final manifestText = await assets.loadString(path);
      if (utf8.encode(manifestText).length > maxManifestBytes) {
        throw const MetaversePluginInstallException('清单过大');
      }
      final json = jsonDecode(manifestText);
      final spec = MetaversePluginManifest.parse(
        json,
        reservedHosts: reservedHosts,
      );
      final dir = path.substring(0, path.lastIndexOf('/') + 1);
      final files = <String, String>{
        for (final name in [spec.uiPath, spec.scriptPath])
          name: await assets.loadString('$dir$name'),
      };
      // 安装包签名覆盖这些资源。同一资源路径升级不应清掉尚待核对的订单。
      packages.add(_checkedFiles(spec, files, 'asset:$path'));
    }
    return packages;
  }

  /// 文件包含清单和两个文本资源，不解压、不读取插件指定的本地路径。
  static const maxBundleBytes = 2 * 1024 * 1024;
  Future<MetaversePluginPackage> importBundle(
    Stream<List<int>> stream, {String? source, String? expectedDigest}
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBundleBytes) {
        throw const MetaversePluginInstallException('插件包过大');
      }
      bytes.add(chunk);
    }
    final raw = bytes.takeBytes();
    if (expectedDigest != null && sha256.convert(raw).toString() != expectedDigest) {
      throw const MetaversePluginInstallException('插件包摘要与市场记录不匹配');
    }
    final bundle = jsonDecode(utf8.decode(raw));
    if (bundle is! Map<String, dynamic> ||
        bundle['files'] is! Map<String, dynamic> ||
        utf8.encode(jsonEncode(bundle['manifest'])).length > maxManifestBytes) {
      throw const MetaversePluginInstallException('插件包结构无效');
    }
    final manifest = MetaversePluginManifest.parse(
      bundle['manifest'],
      reservedHosts: reservedHosts,
    );
    final files = bundle['files'] as Map<String, dynamic>;
    return _checkedFiles(manifest, files, source ?? 'file:${manifest.id}');
  }

  MetaversePluginPackage _checkedFiles(
    MetaversePluginManifest manifest,
    Map<String, dynamic> files,
    String source,
  ) {
    final ui = files[manifest.uiPath], script = files[manifest.scriptPath];
    if (ui is! String ||
        script is! String ||
        utf8.encode(ui).length > maxUiBytes ||
        utf8.encode(script).length > maxScriptBytes) {
      throw const MetaversePluginInstallException('插件资源缺失或过大');
    }
    validateUi(manifest, ui);
    return MetaversePluginPackage(
      manifest: manifest,
      source: source,
      code: (ui: ui, script: script),
    );
  }

  Future<MetaversePluginPackage> fetch(String manifestUrl) async {
    final source = Uri.tryParse(manifestUrl.trim());
    if (source == null || source.scheme != 'https' || source.host.isEmpty) {
      throw const MetaversePluginInstallException('清单地址须为 https 链接');
    }
    try {
      final Object? json;
      try {
        json = jsonDecode(
          await _network.download(source, maxBytes: maxManifestBytes),
        );
      } on FormatException {
        throw const MetaversePluginInstallException('清单不是合法的 JSON');
      }
      final manifest = MetaversePluginManifest.parse(
        json,
        reservedHosts: reservedHosts,
      );

      // 代码文件必须与清单同源：清单路径已限制为相对路径，resolve 不会跨域。
      final ui = await _network.download(
        source.resolve(manifest.uiPath),
        maxBytes: maxUiBytes,
      );
      final script = await _network.download(
        source.resolve(manifest.scriptPath),
        maxBytes: maxScriptBytes,
      );
      validateUi(manifest, ui);
      return MetaversePluginPackage(
        manifest: manifest,
        source: source.toString(),
        code: (ui: ui, script: script),
      );
    } on MetaverseManifestException catch (error) {
      throw MetaversePluginInstallException('清单不合法（$error）');
    } on MetaversePluginCallException catch (error) {
      throw MetaversePluginInstallException(error.message);
    } on FormatException {
      throw const MetaversePluginInstallException('插件文件不是合法的 UTF-8 文本');
    }
  }

  /// 解析界面描述，并确认清单引用的组件都已定义。
  static RemoteWidgetLibrary validateUi(
    MetaversePluginManifest manifest,
    String ui,
  ) {
    final RemoteWidgetLibrary library;
    try {
      library = parseLibraryFile(ui.replaceAll('\r\n', '\n'));
    } on ParserException catch (error) {
      throw MetaversePluginInstallException('界面描述解析失败: $error');
    }
    for (final import in library.imports) {
      if (import.name.parts.join('.') != 'fluxdo') {
        throw MetaversePluginInstallException(
          '界面描述只能 import fluxdo，不能 import ${import.name.parts.join('.')}',
        );
      }
    }
    final defined = {for (final widget in library.widgets) widget.name};
    final required = {
      ?manifest.cardWidget,
      for (final page in manifest.pages) page.widget,
    };
    final missing = required.difference(defined);
    if (missing.isNotEmpty) {
      throw MetaversePluginInstallException('界面描述缺少组件 ${missing.join('、')}');
    }
    return library;
  }
}
