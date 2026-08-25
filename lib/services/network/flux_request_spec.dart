import 'package:dio/dio.dart';

/// 请求语义标记的**单一真相源**。
///
/// 这些标记是拦截器之间以及调用方与拦截器之间的"函数参数",此前散落成
/// 裸字符串字面量:33 个键、89 处触点,读写两侧各自拼写,拼错不会报错,
/// 语义只活在注释里。本类把**键名**与**读取口**收敛到一处:
///
/// - 键名常量([kIsSilent] 等)供写入方引用,避免字面量漂移;
/// - [FluxRequestSpec] 的 getter 是所有读取点的唯一入口,语义与默认值
///   在此定义一次。
///
/// 用法:
/// ```dart
/// // 读取(拦截器内)
/// if (options.spec.isSilent) { ... }
///
/// // 写入(调用方)
/// options: Options(extra: FluxRequestSpec.background().toExtra())
/// // 或就地补键
/// options: Options(extra: {FluxRequestKeys.skipCsrf: true})
/// ```
///
/// 迁移策略:读取侧一次性收口(本类),写入侧渐进迁移——存量字面量与
/// 常量指向同一字符串,两种写法并存期间行为完全一致。
class FluxRequestKeys {
  FluxRequestKeys._();

  // --- 调用方意图 ---

  /// 后台静默请求:不弹错误 toast、CF 盾只后台验证、调度降为低优先级、
  /// 网络日志降为 debug 级。
  static const String isSilent = 'isSilent';

  /// 显式覆盖"是否弹错误 toast"。缺省行为按方法推导(写操作弹、GET 不弹),
  /// 设置本键即三态覆盖。
  static const String showErrorToast = 'showErrorToast';

  /// 显式调度优先级:`'high'` / `'normal'` / `'low'`。
  /// 与 [isSilent] 同时存在时本键优先(搜索类请求靠它抵消静默降级)。
  static const String priority = 'priority';

  /// 诊断链路标签,进网络日志与 CF 检测日志,便于按链路而非 URL 归因。
  static const String requestTag = 'requestTag';

  // --- 逐环节豁免 ---

  /// 跳过 CSRF 注入与"POST 前自动刷新 CSRF"。
  /// 用于登录流/OAuth/下载,以及调用方已手动带 `X-CSRF-Token` 的请求。
  static const String skipCsrf = 'skipCsrf';

  /// 跳过登出信号上报(auth 探测请求本身不应产生 auth 信号)。
  static const String skipAuthCheck = 'skipAuthCheck';

  /// 不自动跟随 3xx。调用方只要这一跳的响应(如 OAuth/OTP 兑换要 302 的
  /// Location 与 Set-Cookie)。
  static const String skipRedirect = 'skipRedirect';

  /// 成功响应不写网络日志(长轮询等高频请求)。
  static const String skipNetworkLog = 'skipNetworkLog';

  /// 响应不回写内存会话状态机(候选会话探测不得污染主会话)。
  static const String skipSessionStateSync = 'skipSessionStateSync';

  /// 不允许被 WebView 适配器接管(带手工 Cookie 头的请求会被 WebView 覆写)。
  static const String skipWebViewAdapter = 'skipWebViewAdapter';

  /// 不走 rhttp 适配器(长轮询需要系统级省电的稳定连接)。
  static const String skipRhttpAdapter = 'skipRhttpAdapter';

  /// 绕过并发/速率调度器(框架内部请求,避免与调用方争抢槽位造成死锁)。
  static const String skipScheduler = 'skipScheduler';

  /// 关闭自动恢复(限流等待、瞬态重试)。
  ///
  /// 用于自己管调度的链路:长轮询要拿原始 429 读 Retry-After 自行退避;
  /// 后台 isolate 没有重试窗口;页面数据有自己的降级路径。
  static const String noRecovery = 'noRecovery';

  /// 3xx 响应上的 Set-Cookie 额外保存到每个 Location 目标域。
  /// OAuth 授权跳转链的会话 cookie 依赖此语义;重定向子请求会继承本键。
  static const String allowRedirectSetCookie = 'allowRedirectSetCookie';

  // --- 防环/内部 ---

  /// CF 验证成功后的重放不得再次触发验证(防验证死循环)。
  static const String skipCfChallenge = 'skipCfChallenge';

  /// CF 重放绕过调度器的"验证期冻结"与浏览器信任门。
  static const String skipCfBlock = 'skipCfBlock';
}

/// 调度优先级取值。
class FluxRequestPriority {
  FluxRequestPriority._();

  static const String high = 'high';
  static const String normal = 'normal';
  static const String low = 'low';
}

/// 请求语义的类型化读取视图。
///
/// 所有拦截器统一通过 `options.spec.xxx` 读取语义,不再各自写
/// `extra['xxx'] == true`。默认值语义在此定义一次。
extension type const FluxRequestSpec(Map<String, dynamic> _extra) {
  bool get isSilent => _extra[FluxRequestKeys.isSilent] == true;

  /// 是否显式指定过 [showErrorToast](三态判定用)。
  bool get hasExplicitErrorToast =>
      _extra.containsKey(FluxRequestKeys.showErrorToast);

  bool get showErrorToast => _extra[FluxRequestKeys.showErrorToast] == true;

  /// 显式优先级;未指定返回 null(由调用方按方法/静默标记推导)。
  String? get explicitPriority {
    final value = _extra[FluxRequestKeys.priority];
    return value is String ? value : null;
  }

  String? get requestTag {
    final value = _extra[FluxRequestKeys.requestTag]?.toString();
    return (value == null || value.isEmpty) ? null : value;
  }

  bool get skipCsrf => _extra[FluxRequestKeys.skipCsrf] == true;

  bool get skipAuthCheck => _extra[FluxRequestKeys.skipAuthCheck] == true;

  bool get skipRedirect => _extra[FluxRequestKeys.skipRedirect] == true;

  bool get skipNetworkLog => _extra[FluxRequestKeys.skipNetworkLog] == true;

  bool get skipSessionStateSync =>
      _extra[FluxRequestKeys.skipSessionStateSync] == true;

  bool get skipWebViewAdapter =>
      _extra[FluxRequestKeys.skipWebViewAdapter] == true;

  bool get skipRhttpAdapter =>
      _extra[FluxRequestKeys.skipRhttpAdapter] == true;

  bool get skipScheduler => _extra[FluxRequestKeys.skipScheduler] == true;

  /// 是否关闭自动恢复。
  ///
  /// 静默请求默认也关闭:长轮询/心跳这类链路自己管退避,拿到原始错误比
  /// 被恢复层加工更有用(MessageBus 靠原始 429 的 Retry-After 计算退避)。
  bool get recoveryDisabled =>
      _extra[FluxRequestKeys.noRecovery] == true || isSilent;

  bool get allowRedirectSetCookie =>
      _extra[FluxRequestKeys.allowRedirectSetCookie] == true;

  bool get skipCfChallenge => _extra[FluxRequestKeys.skipCfChallenge] == true;

  bool get skipCfBlock => _extra[FluxRequestKeys.skipCfBlock] == true;
}

/// 让拦截器与调用方都能写 `options.spec.isSilent`。
extension FluxRequestOptionsSpec on RequestOptions {
  FluxRequestSpec get spec => FluxRequestSpec(extra);
}
