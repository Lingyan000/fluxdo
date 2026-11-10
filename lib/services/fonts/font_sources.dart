import 'font_catalog.dart';

/// 字体下载源。
enum FontSourceKind {
  /// 自动：并发测速，按首字节延迟排序依次尝试。
  auto,

  /// npmmirror 整包（大陆节点）。
  npmmirror,

  /// jsDelivr Fastly 节点单文件。
  fastly,

  /// jsDelivr 默认节点单文件。
  jsdelivr,

  /// unpkg 单文件。
  unpkg,

  /// npm 官方 registry 整包。
  npmjs,

  /// 用户自定义镜像（URL 模板）。
  custom,
}

/// 一个具体的下载源。
class FontSource {
  const FontSource._(
    this.kind, {
    required this.tarball,
    required this.rangeSafe,
    required this.url,
  });

  final FontSourceKind kind;

  /// 下载的是 npm 整包（需解包取出字体文件）还是字体文件本身。
  final bool tarball;

  /// 是否可安全断点续传。
  ///
  /// 部分 CDN 边缘存的是 brotli 压缩体，Range 请求返回压缩体切片且不带
  /// Content-Encoding，续传拼出的文件必坏；只有实测确认按原始字节切片的
  /// 源才开启续传，其余失败后从头下载。
  final bool rangeSafe;

  /// 由字体条目生成下载地址。
  final String Function(FontEntry) url;

  String urlFor(FontEntry entry) => url(entry);

  /// 内置源，「自动」模式下全部参与测速。
  static final List<FontSource> builtins = [
    FontSource._(
      FontSourceKind.npmmirror,
      tarball: true,
      rangeSafe: true,
      url: (e) =>
          'https://registry.npmmirror.com/${e.package}/-/'
          '${e.packageBaseName}-${e.version}.tgz',
    ),
    FontSource._(
      FontSourceKind.fastly,
      tarball: false,
      rangeSafe: true,
      url: (e) =>
          'https://fastly.jsdelivr.net/npm/${e.package}@${e.version}/'
          '${encodeFilePath(e.file)}',
    ),
    FontSource._(
      FontSourceKind.jsdelivr,
      tarball: false,
      rangeSafe: false,
      url: (e) =>
          'https://cdn.jsdelivr.net/npm/${e.package}@${e.version}/'
          '${encodeFilePath(e.file)}',
    ),
    FontSource._(
      FontSourceKind.unpkg,
      tarball: false,
      rangeSafe: false,
      url: (e) =>
          'https://unpkg.com/${e.package}@${e.version}/'
          '${encodeFilePath(e.file)}',
    ),
    FontSource._(
      FontSourceKind.npmjs,
      tarball: true,
      rangeSafe: true,
      url: (e) =>
          'https://registry.npmjs.org/${e.package}/-/'
          '${e.packageBaseName}-${e.version}.tgz',
    ),
  ];

  static FontSource? builtin(FontSourceKind kind) {
    for (final source in builtins) {
      if (source.kind == kind) return source;
    }
    return null;
  }

  /// 自定义镜像：模板支持 `{pkg}`、`{ver}`、`{file}` 占位，按单文件下载。
  /// 例：`https://mirror.example.com/npm/{pkg}@{ver}/{file}`。
  static FontSource custom(String template) => FontSource._(
    FontSourceKind.custom,
    tarball: false,
    rangeSafe: false,
    url: (e) => template
        .replaceAll('{pkg}', e.package)
        .replaceAll('{ver}', e.version)
        .replaceAll('{file}', encodeFilePath(e.file)),
  );

  /// 自定义模板是否可用（http(s) 地址且含 `{file}`）。
  static bool isValidTemplate(String template) {
    final t = template.trim();
    return (t.startsWith('https://') || t.startsWith('http://')) &&
        t.contains('{file}');
  }

  /// 包内路径逐段 URL 编码（文件名可能含空格）。
  static String encodeFilePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');
}
