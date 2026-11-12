import 'dart:convert';
import 'dart:io';

/// 将可通过 HTTPS 发布的插件目录打包，供客户端离线安装。
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('用法：dart run tool/pack_metaverse_plugin.dart <插件目录> <输出文件>');
    exitCode = 64;
    return;
  }
  final root = Directory(args.first).absolute.uri;
  final manifest = jsonDecode(
    await File.fromUri(root.resolve('plugin.json')).readAsString(),
  ) as Map<String, dynamic>;
  final files = <String, String>{};
  for (final key in ['ui', 'script']) {
    final path = manifest[key] as String;
    final uri = Uri.parse(path);
    if (uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.any(
          (part) =>
              part == '..' ||
              part == '.' ||
              part.isEmpty ||
              part.contains('/') ||
              part.contains(r'\'),
        ) ||
        path.startsWith('/')) {
      throw FormatException('资源必须位于插件目录内：$key');
    }
    final file = File.fromUri(root.resolveUri(uri));
    final resolved = File(await file.resolveSymbolicLinks()).absolute.uri;
    final canonicalRoot = Directory(
      await Directory.fromUri(root).resolveSymbolicLinks(),
    ).absolute.uri;
    if (!resolved.toString().startsWith(canonicalRoot.toString())) {
      throw FormatException('资源位于插件目录之外：$key');
    }
    files[path] = await file.readAsString();
  }
  final output = File(args.last);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    jsonEncode({'manifest': manifest, 'files': files}),
  );
  stdout.writeln(output.absolute.path);
}
