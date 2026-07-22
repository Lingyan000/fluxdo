import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;

/// 从**原始 Win32 剪贴板**取位图 → PNG 字节;取不到返回 null。
///
/// 只在 Windows 上有实际动作,其它 dart:io 平台直接返回 null。
/// 背景与实测证据见 `clipboard_image_native.dart` 的文档注释。
///
/// 直接用 `dart:ffi` 绑定 user32/kernel32 的 5 个函数,**不引入 win32 包**
/// —— 只为这一处兜底加一个直接依赖不划算,样板也就几十行。
Uint8List? readClipboardImageNative() {
  if (!Platform.isWindows) return null;
  final api = _Win32Clipboard.instance;
  if (api == null) return null;
  if (api.openClipboard(nullptr) == 0) return null;
  try {
    // 先 CF_DIB:经典头,alpha 语义明确不含歧义。CF_DIBV5 的 32bpp 常见
    // alpha 全 0(写入方不填),按 BGRA 解出来是整张透明图。
    for (final fmt in const [_cfDib, _cfDibV5]) {
      final handle = api.getClipboardData(fmt);
      if (handle == nullptr) continue;
      final ptr = api.globalLock(handle);
      if (ptr == nullptr) continue;
      try {
        final size = api.globalSize(handle);
        if (size < 40) continue; // 连 BITMAPINFOHEADER 都不够
        final dib = ptr.cast<Uint8>().asTypedList(size);
        final decoded = img.decodeBmp(_dibToBmpFile(dib));
        if (decoded == null) continue;
        return Uint8List.fromList(img.encodePng(_fixOpaque(decoded)));
      } catch (e) {
        debugPrint('[ClipboardNative] DIB 解码失败: $e');
      } finally {
        api.globalUnlock(handle);
      }
    }
    return null;
  } catch (e) {
    debugPrint('[ClipboardNative] 读取失败: $e');
    return null;
  } finally {
    api.closeClipboard();
  }
}

const int _cfDib = 8;
const int _cfDibV5 = 17;

/// 剪贴板位图的 alpha 常常是**没意义的填充 0**(写入方只管 RGB)。整张
/// 全 0 会被当成完全透明 —— 实测症状:预览一片空白、PNG 只有几百字节。
/// 只在「全图 alpha 都是 0」时判定为无效并整体置不透明;真正带透明度的
/// 图至少有一个像素 alpha 非 0,不受影响。
img.Image _fixOpaque(img.Image src) {
  if (src.numChannels < 4) return src;
  for (final p in src) {
    if (p.a != 0) return src; // 有有效 alpha,原样保留
  }
  for (final p in src) {
    p.a = 255;
  }
  return src;
}

/// CF_DIB / CF_DIBV5 的内容是 `BITMAPINFOHEADER + (掩码/调色板) + 像素`,
/// **没有文件头**。补 14 字节 `BITMAPFILEHEADER` 即成合法 .bmp。
///
/// `offBits`(像素起始偏移)必须把掩码和调色板都算进去,算错整张图会错位:
/// - 调色板:`biBitCount <= 8` 且 `biClrUsed == 0` 时按 `2^bpp` 项,每项 4 字节;
/// - `BI_BITFIELDS`(compression == 3):经典头后面还有 3 个 DWORD 掩码;
///   V5 头(`biSize >= 108`)自带掩码字段,不能重复计。
Uint8List _dibToBmpFile(Uint8List dib) {
  final info = ByteData.sublistView(dib);
  final biSize = info.getUint32(0, Endian.little);
  final biBitCount = info.getUint16(14, Endian.little);
  final biCompression = info.getUint32(16, Endian.little);
  var biClrUsed = info.getUint32(32, Endian.little);

  if (biClrUsed == 0 && biBitCount <= 8) biClrUsed = 1 << biBitCount;
  var extra = biClrUsed * 4;
  if (biCompression == 3 && biSize < 108) extra += 12;

  final out = Uint8List(14 + dib.length);
  final head = ByteData.sublistView(out);
  head.setUint8(0, 0x42); // 'B'
  head.setUint8(1, 0x4D); // 'M'
  head.setUint32(2, out.length, Endian.little);
  head.setUint32(6, 0, Endian.little); // 保留位
  head.setUint32(10, 14 + biSize + extra, Endian.little); // offBits
  out.setRange(14, out.length, dib);
  return out;
}

typedef _OpenClipboardC = Int32 Function(Pointer<Void>);
typedef _OpenClipboardD = int Function(Pointer<Void>);
typedef _CloseClipboardC = Int32 Function();
typedef _CloseClipboardD = int Function();
typedef _GetClipboardDataC = Pointer<Void> Function(Uint32);
typedef _GetClipboardDataD = Pointer<Void> Function(int);
typedef _GlobalLockC = Pointer<Void> Function(Pointer<Void>);
typedef _GlobalLockD = Pointer<Void> Function(Pointer<Void>);
typedef _GlobalUnlockC = Int32 Function(Pointer<Void>);
typedef _GlobalUnlockD = int Function(Pointer<Void>);
typedef _GlobalSizeC = IntPtr Function(Pointer<Void>);
typedef _GlobalSizeD = int Function(Pointer<Void>);

/// user32/kernel32 的最小绑定(只要这一处兜底用到的 5 个函数)。
class _Win32Clipboard {
  _Win32Clipboard._(this.openClipboard, this.closeClipboard,
      this.getClipboardData, this.globalLock, this.globalUnlock, this.globalSize);

  final _OpenClipboardD openClipboard;
  final _CloseClipboardD closeClipboard;
  final _GetClipboardDataD getClipboardData;
  final _GlobalLockD globalLock;
  final _GlobalUnlockD globalUnlock;
  final _GlobalSizeD globalSize;

  static bool _tried = false;
  static _Win32Clipboard? _instance;

  /// 加载失败(理论上不会,除非 dll 缺失)时返回 null,调用方静默跳过。
  static _Win32Clipboard? get instance {
    if (_tried) return _instance;
    _tried = true;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _instance = _Win32Clipboard._(
        user32.lookupFunction<_OpenClipboardC, _OpenClipboardD>('OpenClipboard'),
        user32
            .lookupFunction<_CloseClipboardC, _CloseClipboardD>('CloseClipboard'),
        user32.lookupFunction<_GetClipboardDataC, _GetClipboardDataD>(
            'GetClipboardData'),
        kernel32.lookupFunction<_GlobalLockC, _GlobalLockD>('GlobalLock'),
        kernel32.lookupFunction<_GlobalUnlockC, _GlobalUnlockD>('GlobalUnlock'),
        kernel32.lookupFunction<_GlobalSizeC, _GlobalSizeD>('GlobalSize'),
      );
    } catch (e) {
      debugPrint('[ClipboardNative] 绑定 Win32 失败: $e');
      _instance = null;
    }
    return _instance;
  }
}
