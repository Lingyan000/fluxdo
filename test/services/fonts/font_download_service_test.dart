import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/fonts/font_archive.dart';
import 'package:fluxdo/services/fonts/font_catalog.dart';
import 'package:fluxdo/services/fonts/font_download_service.dart';
import 'package:fluxdo/services/fonts/font_sources.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 伪字体：TrueType 文件头 + 随机内容。
Uint8List _fakeFont(int size) {
  final bytes = Uint8List(size);
  bytes.setAll(0, [0x00, 0x01, 0x00, 0x00]);
  for (var i = 4; i < size; i++) {
    bytes[i] = (i * 31) & 0xFF;
  }
  return bytes;
}

/// npm 风格整包：文件位于 `package/` 下，额外放一个长路径条目。
Uint8List _tarball(String file, Uint8List font) {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('package/package.json', utf8.encode('{}')))
    ..addFile(
      ArchiveFile.bytes(
        'package/${'very_long_directory_name/' * 5}placeholder.txt',
        utf8.encode('x'),
      ),
    )
    ..addFile(ArchiveFile.bytes('package/$file', font));
  return Uint8List.fromList(GZipEncoder().encode(TarEncoder().encode(archive))!);
}

String _integrity(List<int> bytes) =>
    'sha512-${base64.encode(crypto.sha512.convert(bytes).bytes)}';

FontEntry _entry(Uint8List font, Uint8List tgz, {String file = 'Fake Font.ttf'}) =>
    FontEntry(
      id: 'fake',
      family: 'FakeFont',
      slot: FontSlot.body,
      name: const {'zh': '测试字体', 'en': 'Fake'},
      license: 'OFL-1.1',
      package: '@scope/fake-font',
      version: '1.0.0',
      file: file,
      size: font.length,
      sha256: crypto.sha256.convert(font).toString(),
      tarballSize: tgz.length,
      tarballIntegrity: _integrity(tgz),
    );

/// 按 URL 前缀分派的假网络层。
class _FakeNet {
  final Map<String, Uint8List Function()> bodies = {};
  final Map<String, Duration?> latency = {};
  final Set<String> rangeCapable = {};
  final List<String> requests = [];

  MapEntry<String, Uint8List Function()>? _match(String url) {
    for (final e in bodies.entries) {
      if (url.startsWith(e.key)) return e;
    }
    return null;
  }

  Future<FontHttpResponse> fetch(
    String url, {
    int? from,
    CancelToken? cancelToken,
  }) async {
    requests.add(from == null ? url : '$url@$from');
    final match = _match(url);
    if (match == null) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        message: 'unreachable',
      );
    }
    final data = match.value();
    final ranged = from != null && rangeCapable.contains(match.key);
    final body = ranged ? data.sublist(from) : data;
    return FontHttpResponse(
      ranged ? 206 : 200,
      Stream.fromIterable([
        for (var i = 0; i < body.length; i += 4096)
          body.sublist(i, i + 4096 > body.length ? body.length : i + 4096),
      ]),
    );
  }

  Future<Duration?> probe(String url) async {
    for (final e in latency.entries) {
      if (url.startsWith(e.key)) return e.value;
    }
    return null;
  }
}

const _mirror = 'https://registry.npmmirror.com/';
const _fastly = 'https://fastly.jsdelivr.net/';
const _jsdelivr = 'https://cdn.jsdelivr.net/';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Uint8List font;
  late Uint8List tgz;
  late FontEntry entry;
  late _FakeNet net;
  late SharedPreferences prefs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fonts_test');
    font = _fakeFont(50000);
    tgz = _tarball('Fake Font.ttf', font);
    entry = _entry(font, tgz);
    FontCatalog.setAll([entry]);
    net = _FakeNet();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    FontCatalog.setAll(const []);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<FontDownloadService> service() async {
    final s = FontDownloadService(
      fetch: net.fetch,
      rootDir: () async => tmp,
      probeOverride: net.probe,
    );
    await s.initialize(prefs);
    return s;
  }

  group('FontArchive', () {
    test('从整包流式取出目标文件，跳过长路径条目', () async {
      final tgzFile = File('${tmp.path}/a.tgz')..writeAsBytesSync(tgz);
      final out = '${tmp.path}/out.ttf';
      await FontArchive.extractMember(
        tgzFile.path,
        'package/Fake Font.ttf',
        out,
      );
      expect(File(out).readAsBytesSync(), font);
      expect(await FontArchive.isFontFile(out), isTrue);
      expect(await FontArchive.matchesIntegrity(tgzFile.path, entry.tarballIntegrity), isTrue);
      expect(await FontArchive.sha256Of(out), entry.sha256);
    });

    test('包内缺少目标文件时报错', () async {
      final tgzFile = File('${tmp.path}/a.tgz')..writeAsBytesSync(tgz);
      expect(
        FontArchive.extractMember(tgzFile.path, 'package/none.ttf', '${tmp.path}/x'),
        throwsFormatException,
      );
    });

    test('文件头判定：拒绝 HTML 与 woff2', () {
      expect(FontArchive.isFontMagic([0, 1, 0, 0]), isTrue);
      expect(FontArchive.isFontMagic(ascii.encode('OTTO')), isTrue);
      expect(FontArchive.isFontMagic(ascii.encode('<!DO')), isFalse);
      expect(FontArchive.isFontMagic(ascii.encode('wOF2')), isFalse);
    });
  });

  group('下载与安装', () {
    test('自动模式按测速排序，走整包并安装到以哈希命名的文件', () async {
      net.bodies[_mirror] = () => tgz;
      net.bodies[_fastly] = () => font;
      net.latency[_mirror] = const Duration(milliseconds: 50);
      net.latency[_fastly] = const Duration(milliseconds: 900);
      final s = await service();
      final installed = s.onInstalled.first;
      await s.install(entry);

      expect(await installed, entry);
      final state = s.stateOf(entry);
      expect(state, isA<FontInstalled>());
      expect((state as FontInstalled).path, endsWith('${entry.sha256}.ttf'));
      expect(File(state.path).readAsBytesSync(), font);
      expect(net.requests.single, startsWith(_mirror));
      // 临时文件已清理
      expect(
        Directory('${tmp.path}/fake').listSync().map((f) => f.path.split('/').last),
        ['${entry.sha256}.ttf'],
      );
    });

    test('内容被篡改的源校验失败，自动换到下一个源', () async {
      final tampered = Uint8List.fromList(font)..[100] ^= 0xFF;
      net.bodies[_fastly] = () => tampered;
      net.bodies[_jsdelivr] = () => font;
      net.latency[_fastly] = const Duration(milliseconds: 10);
      net.latency[_jsdelivr] = const Duration(milliseconds: 20);
      final s = await service();
      await s.install(entry);
      expect(s.stateOf(entry), isA<FontInstalled>());
      expect(net.requests.first, startsWith(_fastly));
      expect(net.requests.last, startsWith(_jsdelivr));
    });

    test('源返回 HTML 错误页（伪装 200）被拒绝', () async {
      net.bodies[_fastly] = () => Uint8List.fromList(
        utf8.encode('<!DOCTYPE html>'.padRight(font.length, ' ')),
      );
      final s = await service();
      await s.setSource(FontSourceKind.fastly);
      await s.install(entry);
      final state = s.stateOf(entry);
      expect(state, isA<FontFailed>());
      expect((state as FontFailed).reason, FontFailure.corrupted);
    });

    test('指定的源失败时不自动换源', () async {
      net.bodies[_fastly] = () => font;
      final s = await service();
      await s.setSource(FontSourceKind.npmmirror);
      await s.install(entry);
      final state = s.stateOf(entry);
      expect(state, isA<FontFailed>());
      expect((state as FontFailed).reason, FontFailure.network);
      expect(net.requests.every((u) => u.startsWith(_mirror)), isTrue);
    });

    test('可续传的源从部分文件接着下载', () async {
      net.bodies[_mirror] = () => tgz;
      net.rangeCapable.add(_mirror);
      final s = await service();
      await s.setSource(FontSourceKind.npmmirror);
      final dir = Directory('${tmp.path}/fake')..createSync(recursive: true);
      final half = tgz.length ~/ 2;
      File('${dir.path}/.part-npmmirror').writeAsBytesSync(tgz.sublist(0, half));
      await s.install(entry);
      expect(s.stateOf(entry), isA<FontInstalled>());
      expect(net.requests.single, endsWith('@$half'));
    });

    test('不可续传的源会丢弃旧的部分文件从头下载', () async {
      net.bodies[_jsdelivr] = () => font;
      final s = await service();
      await s.setSource(FontSourceKind.jsdelivr);
      final dir = Directory('${tmp.path}/fake')..createSync(recursive: true);
      File('${dir.path}/.part-jsdelivr').writeAsBytesSync(font.sublist(0, 1000));
      await s.install(entry);
      expect(s.stateOf(entry), isA<FontInstalled>());
      expect(net.requests.single, isNot(endsWith('@1000')));
    });

    test('自定义镜像模板：无效时报错，有效时按模板下载', () async {
      final s = await service();
      await s.setSource(FontSourceKind.custom, customTemplate: 'ftp://bad');
      await s.install(entry);
      expect((s.stateOf(entry) as FontFailed).reason, FontFailure.invalidSource);

      net.bodies['https://mirror.test/'] = () => font;
      await s.setSource(
        FontSourceKind.custom,
        customTemplate: 'https://mirror.test/npm/{pkg}@{ver}/{file}',
      );
      await s.install(entry);
      expect(s.stateOf(entry), isA<FontInstalled>());
      expect(
        net.requests.last,
        'https://mirror.test/npm/@scope/fake-font@1.0.0/Fake%20Font.ttf',
      );
    });

    test('启动扫描识别已安装字体，卸载后回到未安装', () async {
      final dir = Directory('${tmp.path}/fake')..createSync(recursive: true);
      File('${dir.path}/${entry.sha256}.ttf').writeAsBytesSync(font);
      final s = await service();
      expect(s.isInstalled(entry), isTrue);
      await s.uninstall(entry);
      expect(s.stateOf(entry), isA<FontNotInstalled>());
      expect(dir.existsSync(), isFalse);
    });
  });

  test('下载地址：整包与单文件、空格编码', () {
    final mirror = FontSource.builtin(FontSourceKind.npmmirror)!;
    final fastly = FontSource.builtin(FontSourceKind.fastly)!;
    expect(
      mirror.urlFor(entry),
      'https://registry.npmmirror.com/@scope/fake-font/-/fake-font-1.0.0.tgz',
    );
    expect(mirror.tarball, isTrue);
    expect(
      fastly.urlFor(entry),
      'https://fastly.jsdelivr.net/npm/@scope/fake-font@1.0.0/Fake%20Font.ttf',
    );
    expect(FontSource.builtin(FontSourceKind.jsdelivr)!.rangeSafe, isFalse);
  });

  test('jsDelivr 系源不提供超过 50 MB 的单文件，整包源不受限', () {
    final big = FontEntry(
      id: 'big',
      family: 'Big',
      slot: FontSlot.body,
      name: const {'zh': '大字体'},
      license: 'OFL-1.1',
      package: 'big-font',
      version: '1.0.0',
      file: 'Big.ttf',
      size: 60 * 1000 * 1000,
      sha256: '0' * 64,
      tarballSize: 40 * 1000 * 1000,
      tarballIntegrity: 'sha512-x',
    );
    for (final kind in [FontSourceKind.fastly, FontSourceKind.jsdelivr]) {
      expect(FontSource.builtin(kind)!.supports(big), isFalse, reason: kind.name);
      expect(FontSource.builtin(kind)!.supports(entry), isTrue, reason: kind.name);
    }
    for (final kind in [
      FontSourceKind.npmmirror,
      FontSourceKind.unpkg,
      FontSourceKind.npmjs,
    ]) {
      expect(FontSource.builtin(kind)!.supports(big), isTrue, reason: kind.name);
    }
  });

  test('内置字体目录可解析，条目完整', () {
    final fonts = FontCatalog.parse(
      File(FontCatalog.assetPath).readAsStringSync(),
    );
    expect(fonts.map((f) => f.id), containsAll(['misans', 'firacode']));
    expect(fonts.where((f) => f.slot == FontSlot.mono), isNotEmpty);
    for (final f in fonts) {
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.id);
      expect(f.tarballIntegrity, startsWith('sha512-'), reason: f.id);
      expect(f.name['zh'], isNotNull, reason: f.id);
    }
  });
}
