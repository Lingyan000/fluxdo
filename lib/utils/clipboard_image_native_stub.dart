import 'dart:typed_data';

/// 非 dart:io 平台(web)无原生剪贴板访问,恒返回 null。
Uint8List? readClipboardImageNative() => null;
