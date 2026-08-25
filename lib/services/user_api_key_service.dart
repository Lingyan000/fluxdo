import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:uuid/uuid.dart';

import '../constants.dart';
import 'log/log_writer.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'storage/resilient_secure_storage.dart';

/// User API Key 授权与会话自愈服务
///
/// 定位:官方 DiscourseHub 模式——API key 不用于日常 API 流量(限流预算
/// 差一个数量级),只做两件事:
/// 1. 首次授权(/user-api-key/new,WebView 内完成,回调携带加密 payload+OTP)
/// 2. `_t` 猝死时静默补发 OTP(POST /user-api-key/otp)→ 兑换新 _t
///    (POST /session/otp/:token → log_on_user → Set-Cookie _t),用户无感恢复
///
/// 服务端行为依据(discourse 源码):
/// - payload/OTP 均为 RSA PKCS1 公钥加密 + Base64(user_api_keys_controller#one_time_password)
/// - OTP 是 Redis 一次性兑换券,10 分钟 TTL,POST 兑换即焚(session_controller#one_time_password)
/// - 带 User-Api-Key 头的 POST 豁免 CSRF(application_controller#handle_unverified_request)
/// - scopes 只申请 one_time_password:linux.do 的 allow_user_api_key_scopes 收窄过,
///   不含 write,带 write 会因 allowed_scopes.superset? 失败报 generic_error。
///   代价:one_time_password scope 的 RouteMatcher 为空,带此 key 的 User-Api-Key
///   请求会被 ensure_allowed! 拒(仅能授权时随 create 返回一枚一次性 OTP),
///   故 POST /user-api-key/otp 的长期自愈在 linux.do 现配置下不可用——授权登录
///   本身不受影响。selfHeal/requestOtp 对开了 write 的站点仍有效,403 时静默降级。
/// - **用完即焚**:兑换 `_t` 与 key 存活完全解耦(session#one_time_password 只查
///   Redis),且零 scope key 也能自我吊销(allow? 的 is_revoke_self_request? 豁免)。
///   scopes 无 write 时 key 落地即纯负债(永久有效+零用途+用户 Apps 列表常驻),
///   登录收口后立即 revoke+清除;将来站点放开 write 则自动改为保留([keyWorthKeeping])。
/// - auth_redirect 用 discourse://auth_redirect(站点 allowed_user_api_auth_redirects
///   默认白名单,无需站方配置);App 已在 Android/iOS/macOS/Linux 注册 discourse
///   scheme,系统浏览器授权后深链回 App(DiscourseHub 同款流程)
class UserApiKeyService {
  UserApiKeyService._();
  static final UserApiKeyService _instance = UserApiKeyService._();
  factory UserApiKeyService() => _instance;

  static const _keyPrivateKey = 'user_api_key_rsa_private';
  static const _keyApiKey = 'user_api_key_key';
  static const _keyClientId = 'user_api_key_client_id';
  /// 跨设备扫码专用 client_id(与浏览器授权 client 隔离)。
  /// 稳定复用,使服务端 create 时 destroy_all 只清掉上一枚分享 key。
  static const _keyQrClientId = 'user_api_key_qr_client_id';
  // nonce 持久化:跨重启存活。冷启动 getInitialLink 会重放上次的
  // auth_redirect 深链,内存态 nonce 会丢失导致每次重启误报"回调解析失败"。
  static const _keyPendingNonce = 'user_api_key_pending_nonce';

  static const String authRedirect = 'discourse://auth_redirect';
  static const String applicationName = 'FluxDO';
  static const String scopes = 'one_time_password';

  /// 跨设备扫码 key 的 application_name。展示端靠它在
  /// /u/:username.json 的 user_api_keys 列表里识别自己那枚分享 key
  /// (轮询其消失 = 扫码端已登录并自我吊销)。
  static const String qrApplicationName = '$applicationName QR Login';

  /// scopes 是否含 write(决定 key 是否值得留作 _t 自愈弹药)。
  /// linux.do 现配置只允许 one_time_password → key 兑换后即为
  /// 零 scope 永久凭据,纯负债,应当用完即焚。
  static bool get keyWorthKeeping =>
      scopes.split(',').map((s) => s.trim()).contains('write');

  /// 自愈冷却:失败后短期内不再重试,避免 key 已撤销时反复打服务端
  static const Duration _selfHealCooldown = Duration(minutes: 10);

  final _storage = ResilientSecureStorage();
  final _cookieJar = CookieJarService();

  DateTime? _lastSelfHealFailureAt;
  Future<Map<String, dynamic>?>? _activeSelfHeal;

  // ---------- 存储 ----------

  Future<bool> hasKey() async {
    final key = await _storage.read(key: _keyApiKey);
    return key != null && key.isNotEmpty;
  }

  Future<String?> readApiKey() => _storage.read(key: _keyApiKey);

  /// 清除本地凭证(用户显式登出或重置时调用)
  Future<void> clearKey() async {
    await _storage.delete(key: _keyApiKey);
    _lastSelfHealFailureAt = null;
  }

  /// 撤销一枚指定的 User API Key(服务端 revoked_at 置位)。
  ///
  /// 关键依据(discourse user_api_key.rb#allow?):即使 scope 的
  /// RouteMatcher 全空(one_time_password),自我吊销请求
  /// `POST /user-api-key/revoke`(带 User-Api-Key 头、不带 id)
  /// 永远豁免——`is_revoke_self_request?`。带 key 头亦豁免 CSRF。
  /// 因此"零权限 key 焚毁自己"在任何站点配置下都可行。
  Future<bool> revokeKey(Dio dio, String apiKey) async {
    if (apiKey.isEmpty) return false;
    try {
      await dio.post(
        '/user-api-key/revoke',
        options: Options(
          headers: {'User-Api-Key': apiKey},
          extra: const {'skipAuthCheck': true, 'skipCsrf': true},
        ),
      );
      _log('info', 'user_api_key_revoked', '已撤销 User API Key');
      return true;
    } catch (e) {
      _log('warning', 'user_api_key_revoke_failed', '撤销 User API Key 失败(忽略)', {
        'error': e.toString(),
      });
      return false;
    }
  }

  /// 显式登出时尽力撤销服务端 key(失败不阻塞登出)
  Future<void> revokeAndClear(Dio dio) async {
    final key = await readApiKey();
    if (key != null && key.isNotEmpty) {
      await revokeKey(dio, key);
    }
    await clearKey();
  }

  /// 授权登录收口后的"用完即焚":scopes 无 write(本地无自愈价值)时
  /// 撤销并清除刚拿到的 key,不给服务端留永久零权限凭据。
  Future<void> burnAfterLoginIfUseless(Dio dio) async {
    if (keyWorthKeeping) return;
    await revokeAndClear(dio);
  }

  Future<String> _ensureClientId() async {
    var clientId = await _storage.read(key: _keyClientId);
    if (clientId == null || clientId.isEmpty) {
      clientId = const Uuid().v4();
      await _storage.write(key: _keyClientId, value: clientId);
    }
    return clientId;
  }

  /// 跨设备扫码专用 client_id,与 [_ensureClientId] 隔离。
  Future<String> _ensureQrClientId() async {
    var clientId = await _storage.read(key: _keyQrClientId);
    if (clientId == null || clientId.isEmpty) {
      clientId = const Uuid().v4();
      await _storage.write(key: _keyQrClientId, value: clientId);
    }
    return clientId;
  }

  // ---------- RSA ----------

  Future<RSAPrivateKey?> _readPrivateKey() async {
    final raw = await _storage.read(key: _keyPrivateKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return RSAPrivateKey(
        BigInt.parse(map['n'] as String, radix: 16),
        BigInt.parse(map['d'] as String, radix: 16),
        BigInt.parse(map['p'] as String, radix: 16),
        BigInt.parse(map['q'] as String, radix: 16),
      );
    } catch (e) {
      debugPrint('[UserApiKey] 私钥解析失败: $e');
      return null;
    }
  }

  /// 确保 RSA 密钥对存在,返回公钥 PEM(SubjectPublicKeyInfo 格式,
  /// OpenSSL::PKey::RSA.new 直接可读)。密钥生成在后台 isolate,避免掉帧。
  Future<String> ensurePublicKeyPem({bool regenerate = false}) async {
    if (!regenerate) {
      final existing = await _readPrivateKey();
      if (existing != null) return _encodePublicKeyPem(existing);
    }
    final generated = await compute(_generateRsaKeyPairInIsolate, 2048);
    await _storage.write(
      key: _keyPrivateKey,
      value: jsonEncode({
        'n': generated[0],
        'd': generated[1],
        'p': generated[2],
        'q': generated[3],
      }),
    );
    final privateKey = RSAPrivateKey(
      BigInt.parse(generated[0], radix: 16),
      BigInt.parse(generated[1], radix: 16),
      BigInt.parse(generated[2], radix: 16),
      BigInt.parse(generated[3], radix: 16),
    );
    return _encodePublicKeyPem(privateKey);
  }

  String _encodePublicKeyPem(RSAPrivateKey privateKey) {
    final modulus = privateKey.modulus!;
    final publicExponent = privateKey.publicExponent ?? BigInt.from(65537);

    final rsaKeySeq = ASN1Sequence()
      ..add(ASN1Integer(modulus))
      ..add(ASN1Integer(publicExponent));
    final algorithmSeq = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'))
      ..add(ASN1Null());
    final topLevel = ASN1Sequence()
      ..add(algorithmSeq)
      ..add(ASN1BitString(stringValues: rsaKeySeq.encode()));

    final body = base64Encode(topLevel.encode());
    final buffer = StringBuffer('-----BEGIN PUBLIC KEY-----\n');
    for (var i = 0; i < body.length; i += 64) {
      buffer.writeln(body.substring(i, min(i + 64, body.length)));
    }
    buffer.write('-----END PUBLIC KEY-----');
    return buffer.toString();
  }

  /// 解密服务端回传的 Base64(RSA-PKCS1(data))
  Future<String?> _decrypt(String base64Payload) async {
    final privateKey = await _readPrivateKey();
    if (privateKey == null) return null;
    try {
      // Ruby Base64.encode64 每 60 字符插入换行,URL 传输还可能引入空格
      final normalized = base64Payload.replaceAll(RegExp(r'\s+'), '');
      final cipher = base64Decode(normalized);
      final engine = PKCS1Encoding(RSAEngine())
        ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
      return utf8.decode(engine.process(Uint8List.fromList(cipher)));
    } catch (e) {
      debugPrint('[UserApiKey] payload 解密失败: $e');
      return null;
    }
  }

  // ---------- 跨设备扫码:创建可分享的 User API Key ----------

  /// 已登录设备为跨设备扫码创建一枚**独立 client** 的 User API Key。
  ///
  /// 必须使用全新 [client_id],避免 `destroy_all` 清掉本机浏览器授权那枚 key。
  /// 通过 `auth_redirect` 让服务端把 OTP 附在 redirect_url 上(无 redirect 时
  /// JSON 只返回加密 payload,不含 OTP)。
  ///
  /// 服务端 user_api_keys#create 不接受过期参数(表无 expires_at),
  /// key 本身不过期;回收靠站点定时任务或手动 revoke。
  Future<({String apiKey, String otp})> createCrossDeviceKey(Dio dio) async {
    final publicKeyPem = await ensurePublicKeyPem();
    // 与浏览器授权 client_id 隔离;本路径稳定复用,重新生成会撤销上一枚分享 key
    final clientId = await _ensureQrClientId();
    final nonce = const Uuid().v4();

    final data = <String, dynamic>{
      'application_name': qrApplicationName,
      'client_id': clientId,
      'scopes': scopes,
      'public_key': publicKeyPem,
      'nonce': nonce,
      'auth_redirect': authRedirect,
    };

    try {
      final response = await dio.post(
        '/user-api-key',
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: const {
            'X-Requested-With': 'XMLHttpRequest',
            'Accept': 'application/json, text/javascript, */*; q=0.01',
          },
          // 跟随 302 会把 redirect 打到 discourse://,dio 解析失败;
          // JSON 路径直接返回 {redirect_url: ...}; HTML 路径则 302 Location
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
          extra: const {
            // 走会话 CSRF;不要 skipCsrf
            'skipAuthCheck': true,
            'skipRedirect': true,
          },
        ),
      );

      final body = response.data;
      Map<String, dynamic>? map;
      if (body is Map<String, dynamic>) {
        map = body;
      } else if (body is String && body.isNotEmpty) {
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) map = decoded;
        } catch (_) {}
      }

      // 优先 JSON.redirect_url; 其次 302 Location(HTML 协商时)
      var redirectUrl = map?['redirect_url']?.toString();
      if (redirectUrl == null || redirectUrl.isEmpty) {
        redirectUrl = response.headers.value('location');
      }
      if (redirectUrl == null || redirectUrl.isEmpty) {
        _log('warning', 'cross_device_key_no_redirect', '创建跨设备 key 未返回 redirect_url', {
          'statusCode': response.statusCode,
          'hasPayload': map?['payload'] != null,
        });
        throw StateError('服务端未返回授权结果');
      }

      final uri = Uri.parse(redirectUrl);
      final payloadParam = uri.queryParameters['payload'];
      final otpParam = uri.queryParameters['oneTimePassword'];
      if (payloadParam == null || payloadParam.isEmpty) {
        throw StateError('授权结果缺少 payload');
      }
      if (otpParam == null || otpParam.isEmpty) {
        throw StateError('授权结果缺少一次性登录令牌');
      }

      final decrypted = await _decrypt(payloadParam);
      if (decrypted == null) {
        throw StateError('授权结果解密失败');
      }
      final payload = jsonDecode(decrypted) as Map<String, dynamic>;
      final returnedNonce = payload['nonce'] as String?;
      if (returnedNonce != nonce) {
        throw StateError('授权结果 nonce 不匹配');
      }
      final apiKey = payload['key'] as String?;
      if (apiKey == null || apiKey.isEmpty) {
        throw StateError('授权结果无 API Key');
      }

      final otp = await _decrypt(otpParam);
      if (otp == null || otp.isEmpty) {
        throw StateError('一次性登录令牌解密失败');
      }

      _log('info', 'cross_device_key_created', '已创建跨设备 User API Key', {
        'apiKeyLen': apiKey.length,
        'otpLen': otp.length,
      });
      return (apiKey: apiKey, otp: otp);
    } on DioException catch (e) {
      _log('warning', 'cross_device_key_failed', '创建跨设备 User API Key 失败', {
        'statusCode': e.response?.statusCode,
        'errorType': e.type.toString(),
      });
      rethrow;
    }
  }

  // ---------- 授权流程 ----------

  /// 构建授权页 URL(系统浏览器打开;未登录会先被引导到 /login,登录后自动回到授权页)
  Future<Uri> buildAuthorizeUrl() async {
    final publicKeyPem = await ensurePublicKeyPem();
    final clientId = await _ensureClientId();
    final nonce = const Uuid().v4();
    await _storage.write(key: _keyPendingNonce, value: nonce);
    return Uri.parse('${AppConstants.baseUrl}/user-api-key/new').replace(
      queryParameters: {
        'application_name': applicationName,
        'client_id': clientId,
        'scopes': scopes,
        'public_key': publicKeyPem,
        'nonce': nonce,
        'auth_redirect': authRedirect,
      },
    );
  }

  /// 是否为授权回调(discourse://auth_redirect?payload=...&oneTimePassword=...)
  bool isAuthRedirect(Uri uri) =>
      uri.scheme == 'discourse' && uri.host == 'auth_redirect';

  /// 处理授权回调:解密 payload,校验 nonce,持久化 key。
  /// 返回 stale=true 表示"非本次授权流程"(冷启动重放的旧回调、nonce 已消费/
  /// 不匹配等)——调用方应静默忽略,不提示用户。ok/otp 仅在 stale=false 时有意义。
  Future<({bool ok, String? otp, bool stale})> handleAuthRedirect(
    Uri uri,
  ) async {
    final pendingNonce = await _storage.read(key: _keyPendingNonce);

    final payloadParam = uri.queryParameters['payload'];
    if (payloadParam == null || payloadParam.isEmpty) {
      _log('info', 'auth_redirect_missing_payload', '授权回调缺少 payload,忽略');
      return (ok: false, otp: null, stale: true);
    }

    final decrypted = await _decrypt(payloadParam);
    if (decrypted == null) {
      // 解密失败多为残留回调(公钥已轮换),静默忽略
      _log('info', 'auth_redirect_decrypt_failed', '授权回调 payload 解密失败,忽略');
      return (ok: false, otp: null, stale: true);
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(decrypted) as Map<String, dynamic>;
    } catch (e) {
      _log('info', 'auth_redirect_bad_json', '授权回调 payload 非 JSON,忽略: $e');
      return (ok: false, otp: null, stale: true);
    }

    final nonce = payload['nonce'] as String?;
    if (pendingNonce == null || pendingNonce.isEmpty || nonce != pendingNonce) {
      // 无待处理授权 / nonce 对不上 = 非本次流程(冷启动重放旧深链),静默
      _log('info', 'auth_redirect_stale', '授权回调非本次流程(nonce 不匹配),忽略', {
        'hasPending': pendingNonce != null && pendingNonce.isNotEmpty,
      });
      return (ok: false, otp: null, stale: true);
    }
    // 确认是本次授权流程,消费 nonce(此后失败才提示用户)
    await _storage.delete(key: _keyPendingNonce);

    final key = payload['key'] as String?;
    if (key == null || key.isEmpty) {
      _log('warning', 'auth_redirect_missing_key', '授权回调 payload 无 key');
      return (ok: false, otp: null, stale: false);
    }

    await _storage.write(key: _keyApiKey, value: key);
    _lastSelfHealFailureAt = null;

    String? otp;
    final otpParam = uri.queryParameters['oneTimePassword'];
    if (otpParam != null && otpParam.isNotEmpty) {
      otp = await _decrypt(otpParam);
    }

    _log('info', 'user_api_key_authorized', '授权成功,User API Key 已保存', {
      'hasOtp': otp != null,
      'api': payload['api'],
    });
    return (ok: true, otp: otp, stale: false);
  }

  // ---------- OTP 补发与兑换 ----------

  /// 用 API key 静默补发 OTP。
  /// 服务端 302 到 auth_redirect?oneTimePassword=<加密>,从 Location 头解析。
  Future<String?> requestOtp(Dio dio) async {
    final apiKey = await readApiKey();
    if (apiKey == null || apiKey.isEmpty) return null;
    final publicKeyPem = await ensurePublicKeyPem();

    try {
      final response = await dio.post(
        '/user-api-key/otp',
        data: {
          'public_key': publicKeyPem,
          'auth_redirect': authRedirect,
          'application_name': applicationName,
        },
        options: Options(
          headers: {'User-Api-Key': apiKey},
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && (status < 400 || status == 302),
          // 带 User-Api-Key 的请求服务端豁免 CSRF;且此请求发生在会话
          // 疑似失效期间,必须跳过 auth 信号上报避免自我干扰
          extra: const {'skipAuthCheck': true, 'skipCsrf': true},
        ),
      );

      final location = response.headers.value('location');
      if (location == null || location.isEmpty) {
        _log('warning', 'otp_request_no_location',
            'OTP 补发响应无 Location(status=${response.statusCode})');
        return null;
      }
      final otpParam = Uri.parse(location).queryParameters['oneTimePassword'];
      if (otpParam == null || otpParam.isEmpty) {
        _log('warning', 'otp_request_no_otp_param', 'Location 无 oneTimePassword');
        return null;
      }
      final otp = await _decrypt(otpParam);
      if (otp == null) {
        _log('warning', 'otp_decrypt_failed', 'OTP 解密失败');
      }
      return otp;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // 403 = key 已撤销 / scope 不足 / 用户组不满足,key 已不可用则清除
      if (status == 403) {
        _log('warning', 'otp_request_rejected',
            'OTP 补发被拒(403),清除本地 key', {'statusCode': status});
        await clearKey();
      } else {
        _log('warning', 'otp_request_failed', 'OTP 补发请求失败',
            {'statusCode': status, 'errorType': e.type.toString()});
      }
      return null;
    }
  }

  /// 兑换 OTP:POST /session/otp/:token → log_on_user → Set-Cookie 新 _t
  /// (与密码登录同源的完整 UserAuthToken)。返回新 _t,失败返回 null。
  ///
  /// 纯 dio 通道(rhttp/native):
  /// - CSRF 与 POST 都走传入的主 dio(完整拦截器链),而非 CsrfTokenService 的
  ///   独立 dio——后者在后台/失效窗口撞 CF 会静默失败(见事故日志)。主 dio 的
  ///   CfChallengeInterceptor 会在 cf_clearance 失效时兜底(前台弹 CF 验证)。
  /// - CSRF 用主 dio 手动 GET /session/csrf 取,POST 时 skipCsrf + 手动带
  ///   X-CSRF-Token,避免 RequestHeaderInterceptor 回落到独立 dio 刷新。
  Future<String?> redeemOtp(Dio dio, String otp) async {
    // OTP 令牌是 hex,直接拼路径(路由约束 [0-9a-f]+)
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(otp)) {
      _log('warning', 'otp_redeem_bad_format', 'OTP 格式异常,拒绝兑换');
      return null;
    }

    final beforeToken = await _cookieJar.getTToken();
    try {
      // 1. 主 dio 取 CSRF(GET 无需 CSRF;skipCsrf 避免触发独立 dio 刷新;
      //    过 CF 靠 rhttp 指纹 + CfChallengeInterceptor 兜底)
      final csrf = await _fetchCsrfViaMainDio(dio);
      if (csrf == null || csrf.isEmpty) {
        _log('warning', 'otp_redeem_no_csrf', 'OTP 兑换取 CSRF 失败');
        return null;
      }

      // 2. 主 dio POST 兑换(手动带 CSRF,skipCsrf 避免拦截器覆盖/回落独立 dio)
      // skipRedirect:兑换成功是 302 → /,我们只要这一跳的 Set-Cookie _t
      // (AppCookieManager 已落 jar)。若跟随,RedirectInterceptor 会用原 method
      // POST 重发到 / → POST / 404,反而误判兑换失败(_t 其实已到手)。
      final response = await dio.post(
        '/session/otp/$otp',
        options: Options(
          followRedirects: false,
          validateStatus: (status) =>
              status != null && (status < 400 || status == 302),
          headers: {
            'X-CSRF-Token': csrf,
            'X-Requested-With': 'XMLHttpRequest',
          },
          extra: const {
            'skipCsrf': true,
            'skipAuthCheck': true,
            'skipRedirect': true,
            'requestTag': 'otp-redeem',
          },
        ),
      );

      // 成功路径:302 → / 且 Set-Cookie _t(由 AppCookieManager 落 jar)
      final afterToken = await _cookieJar.getTToken();
      final ok = afterToken != null &&
          afterToken.isNotEmpty &&
          afterToken != beforeToken;
      _log(ok ? 'info' : 'warning', 'otp_redeem_finished',
          ok ? 'OTP 兑换成功,已获得新 _t' : 'OTP 兑换后未见新 _t', {
        'statusCode': response.statusCode,
        'hadTokenBefore': beforeToken != null && beforeToken.isNotEmpty,
        'hasTokenAfter': afterToken != null && afterToken.isNotEmpty,
        'tokenChanged': afterToken != beforeToken,
      });
      return ok ? afterToken : null;
    } on DioException catch (e) {
      _log('warning', 'otp_redeem_failed', 'OTP 兑换请求失败', {
        'statusCode': e.response?.statusCode,
        'errorType': e.type.toString(),
      });
      return null;
    }
  }

  /// 用主 dio(完整拦截器链,含 CfChallengeInterceptor)取 CSRF token。
  Future<String?> _fetchCsrfViaMainDio(Dio dio) async {
    final response = await dio.get(
      '/session/csrf',
      options: Options(
        headers: const {
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'application/json, text/javascript, */*; q=0.01',
        },
        extra: const {'skipCsrf': true, 'skipAuthCheck': true},
      ),
    );
    final data = response.data;
    if (data is Map) return data['csrf'] as String?;
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return decoded['csrf'] as String?;
      } catch (_) {}
    }
    return null;
  }

  // ---------- 自愈 ----------

  /// `_t` 猝死后的静默自愈:补发 OTP → 兑换新 _t → 验证会话。
  /// 成功返回 /session/current.json 的 current_user JSON,失败返回 null。
  /// 单飞 + 失败冷却,不会并发或高频打服务端。
  Future<Map<String, dynamic>?> selfHeal(Dio dio) {
    final inFlight = _activeSelfHeal;
    if (inFlight != null) return inFlight;

    final future = _selfHealImpl(dio);
    _activeSelfHeal = future;
    future.whenComplete(() {
      if (identical(_activeSelfHeal, future)) _activeSelfHeal = null;
    });
    return future;
  }

  Future<Map<String, dynamic>?> _selfHealImpl(Dio dio) async {
    if (!await hasKey()) return null;

    final lastFailure = _lastSelfHealFailureAt;
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) < _selfHealCooldown) {
      _log('info', 'self_heal_cooldown', '自愈处于失败冷却期,跳过');
      return null;
    }

    _log('info', 'self_heal_started', '开始 User API Key 会话自愈');

    final otp = await requestOtp(dio);
    if (otp == null) {
      _lastSelfHealFailureAt = DateTime.now();
      return null;
    }

    final newToken = await redeemOtp(dio, otp);
    if (newToken == null) {
      _lastSelfHealFailureAt = DateTime.now();
      return null;
    }

    // 用新 _t 验证会话,拿回 current_user
    try {
      final response = await dio.get(
        '/session/current.json',
        queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
        options: Options(
          extra: const {'skipAuthCheck': true, 'skipCsrf': true},
        ),
      );
      final data = response.data;
      final currentUser = data is Map<String, dynamic>
          ? data['current_user']
          : null;
      if (currentUser is Map<String, dynamic>) {
        _log('info', 'self_heal_success', '会话自愈成功', {
          'username': currentUser['username'],
        });
        return currentUser;
      }
      _log('warning', 'self_heal_verify_failed', '自愈后会话验证无 current_user');
    } on DioException catch (e) {
      _log('warning', 'self_heal_verify_failed', '自愈后会话验证请求失败', {
        'statusCode': e.response?.statusCode,
      });
    }
    _lastSelfHealFailureAt = DateTime.now();
    return null;
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

/// 在后台 isolate 生成 RSA 密钥对(2048 位约数百毫秒~数秒,不能占主线程)。
/// 返回 [n, d, p, q] 的十六进制串。
List<String> _generateRsaKeyPairInIsolate(int bitLength) {
  final secureRandom = FortunaRandom();
  final seedSource = Random.secure();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => seedSource.nextInt(256)),
  );
  secureRandom.seed(KeyParameter(seed));

  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), bitLength, 64),
        secureRandom,
      ),
    );
  final pair = generator.generateKeyPair();
  final privateKey = pair.privateKey;
  return [
    privateKey.modulus!.toRadixString(16),
    privateKey.privateExponent!.toRadixString(16),
    privateKey.p!.toRadixString(16),
    privateKey.q!.toRadixString(16),
  ];
}
