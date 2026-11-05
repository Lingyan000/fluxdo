import 'package:fluxdo/utils/avatar_url.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../utils/url_helper.dart';
import '../widgets/common/smart_avatar.dart' show isSquareAvatarUrl;
import 'blob_image_cache.dart';
import 'dio_http_client.dart' show DownloadPriority;
import 'discourse/discourse_service.dart';

/// 系统通知的发送者头像(已裁成圆形的 PNG)。
class NotificationAvatar {
  const NotificationAvatar({
    required this.url,
    required this.png,
    required this.side,
    this.rgba,
  });

  /// 源头像 URL,落盘文件名按它寻址。
  final String url;

  final Uint8List png;

  /// 边长(像素,正方形)。
  final int side;

  /// 非预乘 RGBA 原始像素,仅 Linux 生成(DBus `image-data` hint 只收
  /// 原始像素;走字节而非文件路径,flatpak 沙箱内的临时目录对宿主通知
  /// 守护进程不可见)。
  final Uint8List? rgba;

  /// 落盘给只认文件路径的平台用。
  ///
  /// [unique] 每次写新文件:Darwin 的通知附件会被系统**移走**到它自己
  /// 的存储,同一路径第二次就不存在了。Windows 通知中心重绘时会回读
  /// 原路径,用按 URL 的稳定文件名(同一发送者反复覆盖,文件数有界)。
  Future<File> writeFile({required bool unique}) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/notificationAvatars');
    await dir.create(recursive: true);
    final hash = md5.convert(utf8.encode(url));
    final suffix = unique ? '_${DateTime.now().microsecondsSinceEpoch}' : '';
    final file = File('${dir.path}/$hash$suffix.png');
    await file.writeAsBytes(png, flush: true);
    return file;
  }
}

/// 按用户名加载系统通知头像。
///
/// 通知推送(`/notification-alert`、`/chat/notification-alert`)只带
/// username 不带头像模板,这里查 card.json 拿 avatar_template,下载走
/// 头像 bucket(与应用内头像共用缓存),再在后台 isolate 里纯 CPU 裁
/// 圆 —— 不走 dart:ui 画布:后台收到推送时 iOS 不给 GPU,toImage 会
/// 拿到坏纹理。
///
/// 加载失败/超时一律返回 null,调用方照常发无头像通知 —— 头像是锦上
/// 添花,不能拖住或吞掉通知本身。
class NotificationAvatarLoader {
  NotificationAvatarLoader._();

  /// 请求档位取服务端 avatar_sizes 内的值:外部存储站点对非标准尺寸
  /// 会 302 到最近档,白绕一跳。
  static const int _requestSize = 192;

  /// 输出边长。Android largeIcon 64dp,xxhdpi 下 192px 已足够,再大只
  /// 是加重跨进程传输。
  static const int _outputSide = 192;

  /// 超时后后台加载继续跑完并写入 memo,同一发送者下一条通知直接命中。
  static const Duration _timeout = Duration(seconds: 3);

  static const int _memoCap = 64;

  /// 小写用户名 → 头像模板。会话级;换头像后 URL 带新版本号,重启即
  /// 刷新,通知场景容忍这点滞后。
  static final LinkedHashMap<String, String> _templateByUsername = LinkedHashMap();

  /// 头像 URL → 裁好的头像。同一发送者连发多条时免重复解码。
  static final LinkedHashMap<String, NotificationAvatar> _avatarByUrl =
      LinkedHashMap();

  static final Map<String, Future<NotificationAvatar?>> _inflight = {};

  static Future<NotificationAvatar?> load(String username) async {
    if (username.isEmpty) return null;
    final key = username.toLowerCase();
    try {
      return await (_inflight[key] ??= _load(username, key).whenComplete(() {
        _inflight.remove(key);
      })).timeout(_timeout);
    } catch (e) {
      debugPrint('[NotificationAvatar] 加载失败 $username: $e');
      return null;
    }
  }

  static Future<NotificationAvatar?> _load(String username, String key) async {
    var template = _templateByUsername[key];
    if (template == null) {
      final user = await DiscourseService().getUserCard(
        username,
        isSilent: true,
      );
      template = user.avatarTemplate;
      if (template == null || template.isEmpty) return null;
      _remember(_templateByUsername, key, template);
    }
    // 每次按当前站点档位解析，避免配置刷新后沿用旧尺寸 URL。
    // 模板端点仍是静态小图，不改走动画原件。
    final url = UrlHelper.resolveUrlWithCdn(
      AvatarUrl.resolve(template, size: _requestSize),
    );

    final cached = _avatarByUrl[url];
    if (cached != null) return cached;

    final bytes = await BlobImageCache.fetch(
      BlobImageCache.avatarBucket,
      url,
      priority: DownloadPriority.high,
    );
    final square = isSquareAvatarUrl(url);
    final withRgba = Platform.isLinux;
    final result = await Isolate.run(
      () => _rasterize(bytes, square: square, withRgba: withRgba),
    );
    if (result == null) return null;
    final avatar = NotificationAvatar(
      url: url,
      png: result.png,
      side: result.side,
      rgba: result.rgba,
    );
    _remember(_avatarByUrl, url, avatar);
    return avatar;
  }

  static void _remember<V>(LinkedHashMap<String, V> memo, String key, V value) {
    memo.remove(key);
    memo[key] = value;
    if (memo.length > _memoCap) memo.remove(memo.keys.first);
  }

  /// 解码首帧 → 居中裁方 → 缩到 [_outputSide] → 圆形遮罩 → PNG。
  /// SVG 等解不了的格式返回 null(退化为无头像)。
  static ({Uint8List png, int side, Uint8List? rgba})? _rasterize(
    Uint8List bytes, {
    required bool square,
    required bool withRgba,
  }) {
    final decoded = img.decodeImage(bytes, frame: 0);
    if (decoded == null) return null;
    // 统一成 8bit RGBA:JPEG 无 alpha 通道,遮罩写不进去。
    final src = decoded.convert(
      format: img.Format.uint8,
      numChannels: 4,
      alpha: 255,
    );
    final edge = math.min(src.width, src.height);
    var image = img.copyCrop(
      src,
      x: (src.width - edge) ~/ 2,
      y: (src.height - edge) ~/ 2,
      width: edge,
      height: edge,
    );
    if (edge > _outputSide) {
      image = img.copyResize(
        image,
        width: _outputSide,
        height: _outputSide,
        interpolation: img.Interpolation.average,
      );
    }
    // 站点定制的方形头像与应用内同口径:10% 圆角。
    _applyRoundedMask(
      image,
      cornerRadius: square ? image.width * 0.1 : image.width / 2,
    );
    return (
      png: img.encodePng(image),
      side: image.width,
      rgba: withRgba ? image.getBytes(order: img.ChannelOrder.rgba) : null,
    );
  }

  /// 圆角矩形距离场遮罩(圆形是圆角 = 半边长的特例),边缘按像素覆盖
  /// 率抗锯齿。
  static void _applyRoundedMask(img.Image image, {required double cornerRadius}) {
    final half = image.width / 2;
    final inner = half - cornerRadius;
    for (final p in image) {
      final qx = (p.x + 0.5 - half).abs() - inner;
      final qy = (p.y + 0.5 - half).abs() - inner;
      final ox = math.max(qx, 0.0);
      final oy = math.max(qy, 0.0);
      final distance = math.sqrt(ox * ox + oy * oy) +
          math.min(math.max(qx, qy), 0.0) -
          cornerRadius;
      final coverage = (0.5 - distance).clamp(0.0, 1.0);
      if (coverage < 1) p.a = p.a * coverage;
    }
  }
}
