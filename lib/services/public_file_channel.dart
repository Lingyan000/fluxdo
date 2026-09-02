import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次公共落盘的结果。
///
/// [uri] 是 Android content uri（`content://...`），可交给
/// [PublicFileChannel.openUri] 打开，也可作为导出历史的 targetRef 持久化：
/// MediaStore 写入的 uri 长期有效，SAF 另存为的 uri 已持久化授权。
/// [displayName] 是文件最终落盘的名字（MediaStore 同名时会自动加序号）。
class PublicSaveResult {
  const PublicSaveResult({required this.uri, required this.displayName});

  final String uri;
  final String displayName;
}

/// 把文件落到系统「公共」位置的原生通道（目前只有 Android 腿）。
///
/// Android 的公共「下载」目录在 scoped storage 下不能用 File API 直写，
/// 必须走 MediaStore；Flutter 生态没有维护中的通用包（media_store_plus
/// 停更、file_saver 实际写的是应用私有目录），所以自己接一条通道。
/// 其它平台没有「公共目录」这一概念（桌面直接写 ~/Downloads、iOS 只有
/// 应用 Documents），[isSupported] 为 false，由调用方走各自的路径。
abstract final class PublicFileChannel {
  static const MethodChannel _channel = MethodChannel('com.fluxdo/public_file');

  /// 当前平台是否有原生腿（Android：MediaStore + SAF；iOS：导出面板）。
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 当前平台是否存在「公共下载目录」这种落点。
  ///
  /// 只有 Android 有（MediaStore）：桌面靠另存为对话框，iOS 沙盒里根本没有
  /// 对外可见的目录。用它来决定要不要给「静默保存到下载目录」这个入口。
  static bool get hasPublicDownloads => isSupported;

  /// 静默写入公共「下载」目录（Android 10+ 走 MediaStore，零权限）。
  ///
  /// 返回 null 表示这条路走不通（Android 9 及以下没有 MediaStore.Downloads
  /// 集合；iOS 沙盒里根本没有公共目录），调用方应换别的落点。
  /// 写入失败会抛 [PlatformException]。
  static Future<PublicSaveResult?> saveToDownloads({
    required String sourcePath,
    required String fileName,
  }) async {
    if (!isSupported) return null;
    final res = await _channel.invokeMapMethod<String, Object?>(
      'saveToDownloads',
      {'sourcePath': sourcePath, 'fileName': fileName},
    );
    return _parse(res);
  }

  /// SAF「另存为」：拉起系统建档界面让用户自选位置。
  ///
  /// 返回 null 表示用户取消（或平台不支持）。写入失败抛 [PlatformException]。
  static Future<PublicSaveResult?> saveAs({
    required String sourcePath,
    required String fileName,
  }) async {
    if (!isSupported) return null;
    final res = await _channel.invokeMapMethod<String, Object?>('saveAs', {
      'sourcePath': sourcePath,
      'fileName': fileName,
    });
    return _parse(res);
  }

  /// 用系统应用打开之前落盘拿到的 content uri。返回是否成功唤起。
  static Future<bool> openUri(String uri, {String? mimeType}) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openUri', {
        'uri': uri,
        'mimeType': mimeType,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('[PublicFileChannel] openUri failed: ${e.message}');
      return false;
    }
  }

  /// 把之前落盘拿到的 content uri 交给系统分享面板。
  ///
  /// share_plus 只吃文件路径，公共目录/SAF 的产物只有 uri，必须走原生
  /// `ACTION_SEND`。返回是否成功唤起。
  static Future<bool> shareUri(String uri, {String? mimeType}) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareUri', {
        'uri': uri,
        'mimeType': mimeType,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('[PublicFileChannel] shareUri failed: ${e.message}');
      return false;
    }
  }

  /// 这个引用是不是 Android 的 content uri（不能用 `File()` 打开）。
  static bool isContentUri(String ref) => ref.startsWith('content://');

  /// null 表示用户取消（或平台没有这条路）。
  ///
  /// [PublicSaveResult.uri] 允许为空：iOS 的导出面板落点在应用沙盒外，返回的
  /// URL 长期不保证可读，所以那边只回 displayName 供提示用。
  static PublicSaveResult? _parse(Map<String, Object?>? res) {
    if (res == null) return null;
    return PublicSaveResult(
      uri: (res['uri'] as String?) ?? '',
      displayName: (res['displayName'] as String?) ?? '',
    );
  }
}
