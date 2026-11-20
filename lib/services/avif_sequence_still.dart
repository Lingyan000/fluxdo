import 'dart:typed_data';

/// 从 AVIF 动画(avis)文件的前缀字节里取出首帧静态图。
///
/// AVIF 规范要求动画文件同时带一个主图项(`meta`/`pitm`/`iloc`),供只认
/// 静态图的解码器使用,内容就是首帧;常见编码器把 `moov` 和首帧都放在文件
/// 开头。所以只要下载到主图项(及其 alpha 等辅助项)的最远结束位置,
/// 再把前缀改写成静态 AVIF,就能拿到首帧而不必下载整个动画:
///
/// - `moov` 改成同尺寸的 `free`,保持 `iloc` 绝对偏移不变;
/// - `ftyp` 主品牌与兼容品牌里的 `avis`/`msf1` 换成 `avif`/`mif1`,解码器
///   不再按序列处理;
/// - `mdat` 的尺寸改为截断后的实际长度。
///
/// 任何结构不符合预期都返回 null,调用方回退下载完整文件。
class AvifSequenceStill {
  AvifSequenceStill._();

  /// [head] 是文件前缀(至少要覆盖 `ftyp`/`meta`)。是动画 AVIF 且主图项
  /// 全部在 `mdat` 内时,返回需要下载到的字节结束位置(不含);否则 null。
  static int? requiredLength(Uint8List head) {
    final layout = _parse(head);
    return layout?.end;
  }

  /// 把至少 [requiredLength] 长的前缀改写成静态 AVIF。结构不符时返回 null。
  static Uint8List? toStill(Uint8List prefix) {
    final layout = _parse(prefix);
    if (layout == null || prefix.length < layout.end) return null;
    final out = Uint8List.fromList(prefix.sublist(0, layout.end));
    final data = ByteData.sublistView(out);

    // ftyp:主品牌(offset 8)+ 兼容品牌(offset 16 起,每 4 字节一个)
    for (
      var o = layout.ftypOffset + 8;
      o + 4 <= layout.ftypOffset + layout.ftypSize;
      o += 4
    ) {
      if (o == layout.ftypOffset + 12) continue; // minor_version
      final brand = String.fromCharCodes(out.sublist(o, o + 4));
      final replacement = switch (brand) {
        'avis' => 'avif',
        'msf1' => 'mif1',
        _ => null,
      };
      if (replacement != null) out.setRange(o, o + 4, replacement.codeUnits);
    }
    out.setRange(
      layout.moovOffset + 4,
      layout.moovOffset + 8,
      'free'.codeUnits,
    );
    final mdatSize = layout.end - layout.mdatOffset;
    if (layout.mdatHeaderSize == 16) {
      data.setUint64(layout.mdatOffset + 8, mdatSize);
    } else {
      data.setUint32(layout.mdatOffset, mdatSize);
    }
    return out;
  }

  static _Layout? _parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    int? ftypOffset, ftypSize, metaOffset, metaSize, moovOffset;
    int? mdatOffset, mdatHeaderSize;
    var off = 0;
    while (off + 8 <= bytes.length) {
      var size = data.getUint32(off);
      final type = String.fromCharCodes(bytes.sublist(off + 4, off + 8));
      var header = 8;
      if (size == 1) {
        if (off + 16 > bytes.length) return null;
        size = data.getUint64(off + 8);
        header = 16;
      } else if (size == 0) {
        // 延伸到文件末尾,只允许出现在 mdat
        if (type != 'mdat') return null;
        size = 1 << 62;
      }
      if (size < header) return null;
      switch (type) {
        case 'ftyp':
          ftypOffset = off;
          ftypSize = size;
        case 'meta':
          metaOffset = off;
          metaSize = size;
        case 'moov':
          moovOffset = off;
        case 'mdat':
          mdatOffset = off;
          mdatHeaderSize = header;
      }
      if (type == 'mdat') break; // mdat 之后的内容不在前缀里,也用不到
      off += size;
    }
    if (ftypOffset != 0 || ftypSize == null || ftypSize < 16) return null;
    if (metaOffset == null || mdatOffset == null || moovOffset == null) {
      return null;
    }
    if (metaOffset + metaSize! > bytes.length) return null;
    if (moovOffset > mdatOffset) return null;
    if (!_hasSequenceBrand(bytes, ftypSize)) return null;

    final iloc = _findChild(
      bytes,
      metaOffset + 12,
      metaOffset + metaSize,
      'iloc',
    );
    if (iloc == null) return null;
    final extents = _ilocExtents(bytes, iloc.$1, iloc.$2);
    if (extents == null || extents.isEmpty) return null;
    var end = 0;
    final mdatDataStart = mdatOffset + mdatHeaderSize!;
    for (final (start, length) in extents) {
      if (start < mdatDataStart || length <= 0) return null;
      if (start + length > end) end = start + length;
    }
    return _Layout(
      ftypOffset: ftypOffset!,
      ftypSize: ftypSize,
      moovOffset: moovOffset,
      mdatOffset: mdatOffset,
      mdatHeaderSize: mdatHeaderSize,
      end: end,
    );
  }

  static bool _hasSequenceBrand(Uint8List bytes, int ftypSize) {
    for (var o = 8; o + 4 <= ftypSize && o + 4 <= bytes.length; o += 4) {
      if (o == 12) continue; // minor_version
      final brand = String.fromCharCodes(bytes.sublist(o, o + 4));
      if (brand == 'avis' || brand == 'msf1') return true;
    }
    return false;
  }

  /// 在 [start, end) 内找子 box,返回 (box 起点, box 结束)。
  static (int, int)? _findChild(
    Uint8List bytes,
    int start,
    int end,
    String type,
  ) {
    final data = ByteData.sublistView(bytes);
    var off = start;
    while (off + 8 <= end) {
      final size = data.getUint32(off);
      if (size < 8 || off + size > end) return null;
      if (String.fromCharCodes(bytes.sublist(off + 4, off + 8)) == type) {
        return (off, off + size);
      }
      off += size;
    }
    return null;
  }

  /// 解析 `iloc`,返回所有 construction_method == 0(文件偏移)的 extent。
  /// 出现引用外部文件或 idat 以外的构造方式时返回 null。
  static List<(int, int)>? _ilocExtents(Uint8List bytes, int start, int end) {
    var p = start + 8;
    if (p + 6 > end) return null;
    final version = bytes[p];
    p += 4;
    final offsetSize = bytes[p] >> 4;
    final lengthSize = bytes[p] & 0xF;
    final baseOffsetSize = bytes[p + 1] >> 4;
    final indexSize = (version == 1 || version == 2) ? bytes[p + 1] & 0xF : 0;
    p += 2;

    int readUint(int size) {
      if (p + size > end) throw const FormatException('iloc 越界');
      var value = 0;
      for (var i = 0; i < size; i++) {
        value = (value << 8) | bytes[p + i];
      }
      p += size;
      return value;
    }

    try {
      final itemCount = version < 2 ? readUint(2) : readUint(4);
      final extents = <(int, int)>[];
      for (var i = 0; i < itemCount; i++) {
        readUint(version < 2 ? 2 : 4); // item_ID
        var method = 0;
        if (version == 1 || version == 2) method = readUint(2) & 0xF;
        final dataReferenceIndex = readUint(2);
        final baseOffset = readUint(baseOffsetSize);
        final extentCount = readUint(2);
        for (var e = 0; e < extentCount; e++) {
          readUint(indexSize);
          final extentOffset = readUint(offsetSize);
          final extentLength = readUint(lengthSize);
          if (method == 1) continue; // idat:数据在 meta 内,已随前缀下载
          if (method != 0 || dataReferenceIndex != 0) return null;
          extents.add((baseOffset + extentOffset, extentLength));
        }
      }
      return extents;
    } on FormatException {
      return null;
    }
  }
}

class _Layout {
  const _Layout({
    required this.ftypOffset,
    required this.ftypSize,
    required this.moovOffset,
    required this.mdatOffset,
    required this.mdatHeaderSize,
    required this.end,
  });

  final int ftypOffset;
  final int ftypSize;
  final int moovOffset;
  final int mdatOffset;
  final int mdatHeaderSize;
  final int end;
}
