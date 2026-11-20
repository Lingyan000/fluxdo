import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sticker.dart';
import '../utils/url_helper.dart';
import 'blob_image_cache.dart';
import 'discourse/discourse_service.dart';
import 'preloaded_data_service.dart';

/// 外站托管的表情在发送前转存到论坛。
///
/// 市场里少数表情托管在别的网站(其他论坛、图床、带防盗链的图片站),
/// 直接外链进帖子可能失效或被拦截。发送前先下载原图、上传到论坛,用论坛
/// 地址插入;「原地址 → 论坛地址」记下来,同一张图只传一次。
///
/// 哪些算论坛自己的域名由站点配置推导([UrlHelper.isTrustedImageHost]:
/// 站点域名及其子域、站点配置的 CDN / S3 CDN),不维护名单。
class StickerTransferService {
  StickerTransferService(
    this._prefs, {
    Future<Uint8List> Function(String url)? download,
    Future<({String url, int? width, int? height})> Function(String path)?
    upload,
    Future<Directory> Function()? tempDirectory,
    bool Function()? siteConfigReady,
  }) : _download = download ?? _defaultDownload,
       _upload = upload ?? _defaultUpload,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory,
       _siteConfigReady =
           siteConfigReady ?? (() => PreloadedDataService().isLoaded);

  /// 转存记录(原地址 → 论坛地址与尺寸)。用户数据,随备份导出。
  static const String _key = 'sticker_transferred';

  final SharedPreferences _prefs;
  final Future<Uint8List> Function(String url) _download;
  final Future<({String url, int? width, int? height})> Function(String path)
  _upload;
  final Future<Directory> Function() _tempDirectory;
  final bool Function() _siteConfigReady;

  /// 是否需要转存:http(s) 地址且不在论坛自己的域名下。
  ///
  /// 站点配置(CDN 域名)还没加载时一律不转存:此时论坛自己的 CDN 也会
  /// 被误判成外站,宁可漏转也不能把整个市场的表情都重传一遍。
  bool needsTransfer(String url) {
    if (!_siteConfigReady()) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }
    return !UrlHelper.isTrustedImageHost(uri);
  }

  /// 已转存过就返回换成论坛地址的表情,否则 null。
  StickerItem? cached(StickerItem item) {
    final record = _records()[item.url];
    if (record is! Map<String, dynamic>) return null;
    final url = record['url'];
    if (url is! String || url.isEmpty) return null;
    return item.copyWith(
      url: url,
      width: record['width'] as int? ?? item.width,
      height: record['height'] as int? ?? item.height,
    );
  }

  /// 下载原图并上传到论坛,返回换成论坛地址的表情。失败时抛出。
  Future<StickerItem> transfer(StickerItem item) async {
    final hit = cached(item);
    if (hit != null) return hit;

    final bytes = await _download(item.url);
    final dir = Directory('${(await _tempDirectory()).path}/sticker_transfer');
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}/${_safeName(item.name)}.${_extensionOf(item.url, bytes)}',
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      final result = await _upload(file.path);
      final transferred = item.copyWith(
        url: result.url,
        width: result.width ?? item.width,
        height: result.height ?? item.height,
      );
      final records = _records()
        ..[item.url] = {
          'url': transferred.url,
          'width': transferred.width,
          'height': transferred.height,
        };
      await _prefs.setString(_key, json.encode(records));
      return transferred;
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Map<String, dynamic> _records() {
    final raw = _prefs.getString(_key);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.of(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return {};
    }
  }

  /// 上传时的文件名即帖子里看到的附件名:保留表情名,去掉路径分隔等字符。
  static String _safeName(String name) {
    final base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    final cleaned = base.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_').trim();
    return cleaned.isEmpty
        ? md5.convert(utf8.encode(name)).toString().substring(0, 12)
        : cleaned;
  }

  /// 扩展名决定论坛按什么格式收:先按文件头判断,认不出再看地址。
  @visibleForTesting
  static String extensionOf(String url, Uint8List bytes) =>
      _extensionOf(url, bytes);

  static String _extensionOf(String url, Uint8List bytes) {
    bool startsWith(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith([0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (startsWith([0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (startsWith([0xFF, 0xD8, 0xFF])) return 'jpg';
    if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
      return 'webp';
    }
    if (startsWith('ftyp'.codeUnits, 4)) return 'avif';
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1) : '';
    return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : 'png';
  }

  static Future<Uint8List> _defaultDownload(String url) =>
      BlobImageCache.fetch(BlobImageCache.stickerOriginalBucket, url);

  static Future<({String url, int? width, int? height})> _defaultUpload(
    String path,
  ) async {
    final result = await DiscourseService().uploadImage(path);
    final url = result.url;
    if (url == null || url.isEmpty) {
      throw StateError('upload returned no url');
    }
    return (
      url: UrlHelper.resolveUrlWithCdn(url),
      width: result.width,
      height: result.height,
    );
  }
}
