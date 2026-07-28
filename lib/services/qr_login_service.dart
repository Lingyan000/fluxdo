import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import 'discourse/discourse_service.dart';
import 'log/log_writer.dart';
import 'user_api_key_service.dart';

/// 扫码登录 payload。
///
/// 由**已登录设备**在用户二次确认后向服务端创建 User API Key(+OTP),
/// 封装进二维码; **待登录设备**扫码后保存 API Key,用 OTP 兑换 `_t`,
/// 再走与密码/浏览器授权一致的 [DiscourseService.finalizeNativeLoginSuccess]
/// 收口。
///
/// 协议 (v2):
/// ```
/// fluxdo://qr-login?v=2&k=<api_key>&o=<otp>&u=<username>&exp=<unix_ms|0>
/// ```
/// - `k`: User API Key(明文,等同临时分享登录能力,UI 需提示勿外泄)
/// - `o`: 服务端随 create 下发的一次性 OTP(约 10 分钟有效,兑换即焚)
/// - `exp`: API Key 过期时间 UTC 毫秒; `0` 表示不过期
/// - 不传 `_t`/密码;二维码只传 API Key + OTP
class QrLoginPayload {
  const QrLoginPayload({
    required this.version,
    required this.apiKey,
    required this.otp,
    required this.username,
    this.expiresAt,
  });

  final int version;
  final String apiKey;
  final String otp;
  final String username;

  /// API Key 服务端过期时间; `null` 表示不过期。
  final DateTime? expiresAt;

  bool get neverExpires => expiresAt == null;

  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().toUtc().isAfter(exp.toUtc());
  }

  Duration get remaining {
    final exp = expiresAt;
    if (exp == null) return Duration.zero;
    final left = exp.toUtc().difference(DateTime.now().toUtc());
    return left.isNegative ? Duration.zero : left;
  }
}

/// 扫码登录结果
enum QrLoginError {
  /// 不是 FluxDO 扫码登录二维码 / 解析失败
  invalid,

  /// 版本不支持
  unsupportedVersion,

  /// API Key 已过期
  expired,

  /// 本机当前没有可分享的登录会话(展示端)
  noSession,

  /// 用户取消二次确认
  cancelled,

  /// 服务端创建 API Key 失败
  createFailed,

  /// 写入凭证或收口失败
  applyFailed,
}

/// 扫码登录服务
class QrLoginService {
  QrLoginService._();
  static final QrLoginService instance = QrLoginService._();

  static const String scheme = 'fluxdo';
  static const String host = 'qr-login';
  static const int currentVersion = 2;

  /// 把 [payload] 编码为二维码字符串(稳定、可单测)。
  String encodePayload(QrLoginPayload payload) {
    return Uri(
      scheme: scheme,
      host: host,
      queryParameters: {
        'v': '${payload.version}',
        'k': payload.apiKey,
        'o': payload.otp,
        'u': payload.username,
        'exp': payload.expiresAt == null
            ? '0'
            : '${payload.expiresAt!.toUtc().millisecondsSinceEpoch}',
      },
    ).toString();
  }

  /// 解析扫到的原始字符串。非法内容返回 null(不抛)。
  QrLoginPayload? parsePayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != scheme) return null;
    // 兼容 fluxdo://qr-login?... (host) 与 fluxdo:///qr-login?... (path)
    final hostOrPath = uri.host.isNotEmpty
        ? uri.host
        : (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '');
    if (hostOrPath != host) return null;

    final version = int.tryParse(uri.queryParameters['v'] ?? '');
    if (version == null) return null;

    // v2+ 字段: api-key + otp。版本校验留给 requireValidPayload,
    // 以便区分 invalid 与 unsupportedVersion。
    final apiKey = uri.queryParameters['k']?.trim() ?? '';
    final otp = uri.queryParameters['o']?.trim() ?? '';
    final username = uri.queryParameters['u']?.trim() ?? '';
    final expRaw = uri.queryParameters['exp']?.trim() ?? '0';
    final expMs = int.tryParse(expRaw);
    if (apiKey.isEmpty || otp.isEmpty || expMs == null || expMs < 0) {
      return null;
    }
    return QrLoginPayload(
      version: version,
      apiKey: apiKey,
      otp: otp,
      username: username,
      expiresAt: expMs == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expMs, isUtc: true),
    );
  }

  /// 校验并返回可用 payload;失败抛 [QrLoginException]。
  QrLoginPayload requireValidPayload(String raw) {
    final payload = parsePayload(raw);
    if (payload == null) {
      throw const QrLoginException(QrLoginError.invalid, '无效的登录二维码');
    }
    if (payload.version != currentVersion) {
      throw const QrLoginException(
        QrLoginError.unsupportedVersion,
        '二维码版本不受支持,请升级 App',
      );
    }
    if (payload.isExpired) {
      throw const QrLoginException(QrLoginError.expired, '登录凭证已过期,请让对方重新生成');
    }
    return payload;
  }

  /// 已登录设备:经用户批准后创建可分享的 User API Key,组装二维码字符串。
  ///
  /// [expiresIn] 为 `null` 表示 API Key 不过期(默认);传入正时长则带
  /// `expires_in_seconds` 创建。
  Future<({String raw, QrLoginPayload payload})> buildPayload({
    Duration? expiresIn,
    String? username,
    Dio? dio,
  }) async {
    var resolvedUsername = username?.trim() ?? '';
    if (resolvedUsername.isEmpty) {
      try {
        resolvedUsername = await DiscourseService().getUsername() ?? '';
      } catch (e) {
        debugPrint('[QrLogin] 取 username 失败(可忽略): $e');
      }
    }

    final service = UserApiKeyService();
    final created = await service.createCrossDeviceKey(
      dio ?? DiscourseService().dio,
      expiresIn: expiresIn,
    );

    final payload = QrLoginPayload(
      version: currentVersion,
      apiKey: created.apiKey,
      otp: created.otp,
      username: resolvedUsername,
      expiresAt: created.expiresAt,
    );
    final raw = encodePayload(payload);
    _log('info', 'qr_login_payload_built', '已生成扫码登录 API Key 二维码', {
      'neverExpires': payload.neverExpires,
      'expiresInSec': expiresIn?.inSeconds,
      'username': resolvedUsername,
      'apiKeyLen': created.apiKey.length,
      'otpLen': created.otp.length,
    });
    return (raw: raw, payload: payload);
  }

  /// 待登录设备:用扫到的内容完成登录。
  ///
  /// 成功返回解析出的用户名(可能为空);失败抛 [QrLoginException]。
  Future<String> loginWithScannedContent(String raw) async {
    final payload = requireValidPayload(raw);

    try {
      final userApiKeyService = UserApiKeyService();
      await userApiKeyService.persistSharedKey(payload.apiKey);

      final service = DiscourseService();
      final token = await userApiKeyService.redeemOtp(service.dio, payload.otp);
      if (token == null || token.isEmpty) {
        throw const QrLoginException(
          QrLoginError.applyFailed,
          '登录令牌兑换失败,二维码可能已失效,请让对方重新生成',
        );
      }

      var username = payload.username;
      if (username.isEmpty) {
        try {
          final response = await service.dio.get(
            '/session/current.json',
            options: Options(
              extra: const {'skipAuthCheck': true, 'skipCsrf': true},
            ),
          );
          final data = response.data;
          final currentUser = data is Map<String, dynamic>
              ? data['current_user']
              : null;
          if (currentUser is Map<String, dynamic>) {
            username = currentUser['username']?.toString() ?? '';
          }
        } catch (e) {
          debugPrint('[QrLogin] 取 current_user 失败: $e');
        }
      }

      final identifier = username.isNotEmpty ? username : 'user';
      await service.finalizeNativeLoginSuccess(identifier);

      _log('info', 'qr_login_success', '扫码登录成功', {
        'username': username,
        'apiKeyLen': payload.apiKey.length,
      });
      return username;
    } on QrLoginException {
      rethrow;
    } catch (e, st) {
      debugPrint('[QrLogin] 应用登录态失败: $e\n$st');
      _log('warning', 'qr_login_apply_failed', '扫码登录收口失败', {
        'error': e.toString(),
      });
      throw QrLoginException(QrLoginError.applyFailed, '登录失败: $e');
    }
  }

  /// 从图片字节解码二维码文本(相册/截图兜底,全平台可用)。
  /// 找不到二维码返回 null。
  Future<String?> decodeQrFromImageBytes(Uint8List bytes) async {
    try {
      return await compute(_decodeQrInIsolate, bytes);
    } catch (e) {
      debugPrint('[QrLogin] 图片解码二维码失败: $e');
      return null;
    }
  }

  void _log(
    String level,
    String event,
    String message, [
    Map<String, dynamic>? fields,
  ]) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': level,
      'type': 'auth',
      'event': event,
      'message': message,
      ...?fields,
    });
  }
}

/// 扫码登录业务异常
class QrLoginException implements Exception {
  const QrLoginException(this.error, this.message);
  final QrLoginError error;
  final String message;

  @override
  String toString() => 'QrLoginException($error): $message';
}

/// isolate 入口:图片 → 二维码文本
String? _decodeQrInIsolate(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return null;

  // 大图缩到合理宽度,加快解码且不伤识别
  final src = image.width > 1200
      ? img.copyResize(image, width: 1200)
      : image;

  final abgr = src
      .convert(numChannels: 4)
      .getBytes(order: img.ChannelOrder.abgr)
      .buffer
      .asInt32List();
  final source = RGBLuminanceSource(src.width, src.height, abgr);
  final bitmap = BinaryBitmap(HybridBinarizer(source));
  try {
    return QRCodeReader().decode(bitmap).text;
  } catch (_) {
    // 反色再试一次(深色主题截图常见)
    try {
      final inverted = BinaryBitmap(
        HybridBinarizer(InvertedLuminanceSource(source)),
      );
      return QRCodeReader().decode(inverted).text;
    } catch (_) {
      return null;
    }
  }
}
