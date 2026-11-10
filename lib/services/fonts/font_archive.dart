import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 字体包校验与解包（在后台 isolate 执行，不占 UI 线程）。
class FontArchive {
  FontArchive._();

  /// 文件的 npm 完整性串是否为 [integrity]（`sha512-<base64>`）。
  static Future<bool> matchesIntegrity(String path, String integrity) =>
      Isolate.run(() async {
        final digest = await sha512.bind(File(path).openRead()).first;
        return 'sha512-${base64.encode(digest.bytes)}' == integrity;
      });

  /// 文件的 sha256（十六进制小写）。
  static Future<String> sha256Of(String path) => Isolate.run(() async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  });

  /// 文件头是否为 TrueType / OpenType 字体（拒绝 HTML 错误页等伪装成功的
  /// 响应，以及 woff2 等引擎跨平台支持未经验证的格式）。
  static Future<bool> isFontFile(String path) async {
    final raf = await File(path).open();
    try {
      final head = await raf.read(4);
      return isFontMagic(head);
    } finally {
      await raf.close();
    }
  }

  static bool isFontMagic(List<int> head) {
    if (head.length < 4) return false;
    final tag = String.fromCharCodes(head.take(4));
    final isTrueType =
        head[0] == 0x00 && head[1] == 0x01 && head[2] == 0x00 && head[3] == 0x00;
    return isTrueType || tag == 'OTTO' || tag == 'true' || tag == 'ttcf';
  }

  /// 从 npm 整包 [tgzPath] 中流式取出 [member]（如 `package/a.ttf`）写到
  /// [outPath]。找到并写完即停止读取；包内不存在时抛 [FormatException]。
  static Future<void> extractMember(
    String tgzPath,
    String member,
    String outPath,
  ) => Isolate.run(() => _extract(tgzPath, member, outPath));
}

Future<void> _extract(String tgzPath, String member, String outPath) async {
  final parser = _TarMemberParser(member, File(outPath).openWrite());
  final input = File(tgzPath).openRead().transform(gzip.decoder);
  final completer = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = input.listen(
    (chunk) {
      try {
        if (parser.add(chunk)) {
          unawaited(sub.cancel());
          parser.close().then(completer.complete, onError: completer.completeError);
        }
      } catch (e, s) {
        unawaited(sub.cancel());
        parser.close().whenComplete(() => completer.completeError(e, s));
      }
    },
    onError: (Object e, StackTrace s) {
      parser.close().whenComplete(() => completer.completeError(e, s));
    },
    onDone: () {
      if (completer.isCompleted) return;
      parser.close().whenComplete(
        () => completer.completeError(FormatException('包内缺少 $member')),
      );
    },
    cancelOnError: true,
  );
  await completer.future;
  if (!parser.found) throw FormatException('包内缺少 $member');
}

/// tar 流式解析：只把目标成员的数据写入 [_sink]。
///
/// 支持 ustar 前缀、GNU 长文件名（`L`）与 pax 扩展头（`x`）里的 path。
class _TarMemberParser {
  _TarMemberParser(this._target, this._sink);

  final String _target;
  final IOSink _sink;

  final BytesBuilder _header = BytesBuilder(copy: true);
  bool found = false;
  bool _done = false;

  /// 当前条目剩余数据 / 对齐填充字节数。
  int _dataLeft = 0;
  int _padLeft = 0;

  /// 当前条目的处理方式。
  _EntryKind _kind = _EntryKind.skip;
  final BytesBuilder _meta = BytesBuilder(copy: true);

  /// 由 `L` / `x` 头指定、作用于下一个条目的名字。
  String? _pendingName;

  /// 喂入一段解压后的字节；目标成员写完时返回 true。
  bool add(List<int> chunk) {
    var i = 0;
    while (i < chunk.length && !_done) {
      if (_dataLeft > 0) {
        final n = _min(_dataLeft, chunk.length - i);
        final slice = chunk.sublist(i, i + n);
        switch (_kind) {
          case _EntryKind.target:
            _sink.add(slice);
          case _EntryKind.longName || _EntryKind.pax:
            _meta.add(slice);
          case _EntryKind.skip:
            break;
        }
        _dataLeft -= n;
        i += n;
        if (_dataLeft == 0) _finishEntry();
        continue;
      }
      if (_padLeft > 0) {
        final n = _min(_padLeft, chunk.length - i);
        _padLeft -= n;
        i += n;
        continue;
      }
      final need = 512 - _header.length;
      final n = _min(need, chunk.length - i);
      _header.add(chunk.sublist(i, i + n));
      i += n;
      if (_header.length == 512) _parseHeader(_header.takeBytes());
    }
    return _done;
  }

  void _parseHeader(Uint8List h) {
    if (h.every((b) => b == 0)) {
      _done = true; // 归档结束块
      return;
    }
    final size = _octal(h, 124, 12);
    final type = h[156];
    final name = _pendingName ?? _joinUstarName(h);
    _pendingName = null;
    _dataLeft = size;
    _padLeft = (512 - size % 512) % 512;
    _kind = switch (type) {
      0x4C => _EntryKind.longName, // 'L'
      0x78 => _EntryKind.pax, // 'x'
      _ => name == _target ? _EntryKind.target : _EntryKind.skip,
    };
    if (_kind == _EntryKind.target) found = true;
    if (_dataLeft == 0) _finishEntry();
  }

  void _finishEntry() {
    switch (_kind) {
      case _EntryKind.target:
        _done = true;
      case _EntryKind.longName:
        _pendingName = _cString(_meta.takeBytes(), 0, null);
      case _EntryKind.pax:
        final records = utf8.decode(_meta.takeBytes(), allowMalformed: true);
        final match = RegExp(r'\d+ path=([^\n]*)\n').firstMatch(records);
        if (match != null) _pendingName = match.group(1);
      case _EntryKind.skip:
        break;
    }
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }

  static String _joinUstarName(Uint8List h) {
    final name = _cString(h, 0, 100);
    final isUstar = String.fromCharCodes(h.sublist(257, 262)) == 'ustar';
    final prefix = isUstar ? _cString(h, 345, 155) : '';
    return prefix.isEmpty ? name : '$prefix/$name';
  }

  static String _cString(Uint8List bytes, int start, int? length) {
    final end = length == null ? bytes.length : start + length;
    var stop = start;
    while (stop < end && bytes[stop] != 0) {
      stop++;
    }
    return utf8.decode(bytes.sublist(start, stop), allowMalformed: true);
  }

  static int _octal(Uint8List h, int start, int length) {
    final text = String.fromCharCodes(
      h.sublist(start, start + length).where((b) => b != 0 && b != 0x20),
    );
    return text.isEmpty ? 0 : int.parse(text, radix: 8);
  }

  static int _min(int a, int b) => a < b ? a : b;
}

enum _EntryKind { target, skip, longName, pax }
