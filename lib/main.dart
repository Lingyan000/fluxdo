import 'dart:async';
import 'dart:io';

import 'package:catcher_2/catcher_2.dart';
import 'package:chinese_font_library/chinese_font_library.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_animated_image/native_animated_image.dart'
    show NativeAnimatedImageProvider;
import 'package:window_manager/window_manager.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'pages/topics_page.dart';
import 'pages/data_management_page.dart';
import 'providers/discourse_providers.dart';
import 'providers/selected_topic_provider.dart';
import 'providers/locale_provider.dart';
import 'widgets/ai/builtin_presets_factory.dart';
import 'providers/message_bus_providers.dart';
import 'providers/chat/chat_notification_alert_provider.dart';
import 'services/auth_issue_notice_service.dart';
import 'providers/app_state_refresher.dart';
import 'services/highlighter_service.dart';
import 'widgets/common/notification_icon_button.dart';
import 'widgets/common/anchor_guard_sliver.dart';
import 'widgets/common/fullscreen_swipe_back.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'services/network/cookie/csrf_token_service.dart';
import 'services/network/system_proxy_service.dart';
import 'services/network/cookie/cookie_devtools_extension.dart';
import 'services/network/cookie/cookie_jar_service.dart';
import 'services/network/cookie/cookie_store_observer.dart';
import 'services/network/adapters/cronet_fallback_service.dart';
import 'services/local_notification_service.dart';
import 'services/data_management/cache_size_service.dart';
import 'services/discourse_cache_manager.dart';
import 'services/toast_service.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'l10n/s.dart';

import 'services/network/doh/network_settings_service.dart';
import 'services/network/proxy/proxy_settings_service.dart';
import 'services/network/rhttp/rhttp_settings_service.dart';
import 'services/network/webview/webview_adapter_settings_service.dart';
import 'services/eruda_settings_service.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'services/network/vpn_auto_toggle_service.dart';
import 'services/network/doh_proxy/proxy_certificate.dart';
import 'services/cf_challenge_logger.dart';
import 'services/browser_trust_coordinator.dart';
import 'services/update_service.dart';
import 'services/update_checker_helper.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show FlattenCache, FoldShiftHook, ParagraphLayoutCache;

import 'services/clipboard_topic_link_service.dart';
import 'services/deep_link_service.dart';
import 'services/windows_protocol_registrar_stub.dart'
    if (dart.library.ffi) 'services/windows_protocol_registrar_io.dart';
import 'services/background/background_notification_service.dart';
import 'services/message_bus_service.dart';
import 'services/connectivity_service.dart';
import 'services/log/json_file_handler.dart';
import 'services/log/filtered_catcher_logger.dart';
import 'services/log/log_writer.dart';
import 'services/download_service.dart';
import 'services/migration_service.dart';
import 'services/navigation/app_route_observer.dart';
import 'services/navigation/back_exit_guard.dart';
import 'services/navigation/keyboard_focus_guard.dart';
import 'services/window_state_service.dart';
import 'services/webview_settings.dart';
import 'services/windows_webview_environment_service.dart';
import 'services/user_presence_service.dart';
import 'models/user.dart';
import 'constants.dart';
import 'providers/connectivity_provider.dart';
import 'utils/dialog_utils.dart';
import 'utils/frame_jank_monitor.dart';
import 'utils/hashtag_handlers.dart';
import 'utils/image_decode_gate.dart';
import 'widgets/post/post_item/render_parse_cache.dart';
import 'utils/scroll_busy_signal.dart';
import 'theme/theme_resolver.dart';
import 'widgets/common/app_background_layer.dart';
import 'utils/time_utils.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_model_manager/ai_model_manager.dart';
import 'services/app_logger.dart';
import 'services/network/adapters/platform_adapter.dart';
import 'providers/preferences_provider.dart';
import 'providers/theme_provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'services/audio/just_audio_gst.dart';
import 'widgets/preheat_gate.dart';
import 'widgets/onboarding_gate.dart';
import 'widgets/layout/adaptive_scaffold.dart';
import 'widgets/layout/adaptive_navigation.dart';
import 'widgets/esc_fallback_observer.dart';
import 'widgets/layout/master_detail_layout.dart';
import 'widgets/layout/pane_projection_back_scope.dart';
import 'widgets/notification/notification_quick_panel.dart';
import 'widgets/topic/category_drawer.dart' show CategoryDrawerHost;
import 'widgets/read_later/read_later_bubble.dart';
import 'navigation/nav_action_bus.dart';
import 'navigation/nav_entry.dart';
import 'navigation/nav_entry_registry.dart';
import 'providers/read_later_provider.dart';
import 'providers/shortcut_provider.dart';
import 'widgets/keyboard_shortcut_handler.dart';
import 'utils/platform_utils.dart';
import 'utils/discourse_url_parser.dart';

/// 初始化 rhttp Rust runtime
Future<bool> _initRhttp() async {
  await rhttp.Rhttp.init();
  return true;
}

/// 应用 Android 屏幕刷新率偏好。
/// 偏好值 0 表示跟随系统（auto），非 0 则按目标刷新率从 supported 中选最匹配的 mode。
/// 失败不阻塞启动。
Future<void> _applyAndroidDisplayMode(SharedPreferences prefs) async {
  final targetRate = prefs.getInt('pref_display_mode_refresh_rate') ?? 0;
  try {
    if (targetRate == 0) {
      await FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
      return;
    }
    final modes = await FlutterDisplayMode.supported;
    final active = await FlutterDisplayMode.active;
    // 优先选分辨率匹配 active 的相同刷新率 mode；否则退化为任意分辨率
    final matches = modes
        .where((m) => m.refreshRate.round() == targetRate)
        .toList();
    if (matches.isEmpty) {
      await FlutterDisplayMode.setPreferredMode(DisplayMode.auto);
      return;
    }
    final picked = matches.firstWhere(
      (m) => m.width == active.width && m.height == active.height,
      orElse: () => matches.first,
    );
    await FlutterDisplayMode.setPreferredMode(picked);
  } catch (e) {
    debugPrint('[Main] 应用屏幕刷新率失败: $e');
  }
}

Future<void> main() async {
  // 自定义 binding:接管标准图片解码入口,全局限制解码并发(= 限制
  // Impeller 纹理上传并发,图密话题快滚 raster 尖峰的对症闸门,
  // 见 image_decode_gate.dart)。
  FluxdoWidgetsBinding.ensureInitialized();

  // just_audio 不自带 Windows/Linux 实现,必须在创建 AudioPlayer 前注册
  // 后端,否则会落回不存在的 MethodChannel 实现。两平台后端不同:
  // - Windows: MediaKit(libmpv-2.dll 随 media_kit_libs_windows_video 打包,
  //   与视频后端共用同一份 dll);
  // - Linux: GStreamer 桥(见 just_audio_gst.dart 注释;音频不改走 mpv,
  //   GStreamer 桥已稳定,换后端无收益)。
  if (!kIsWeb && Platform.isLinux) {
    JustAudioGst.registerWith();
  } else {
    JustAudioMediaKit.ensureInitialized(linux: false);
  }

  // video_player 官方无 Windows/Linux 后端,两平台桥接到 media_kit(libmpv),
  // 必须先于任何 VideoPlayerController 创建。其余平台维持官方后端。
  // Linux 运行期 dlopen libmpv.so.2 失败时,controller.initialize() 抛错,
  // 走播放器的错误卡兜底(「用浏览器打开」),不影响其他功能。
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    VideoPlayerMediaKit.ensureInitialized(windows: true, linux: true);
  }

  // Rust 动图管线的首帧(挂载瞬态的裸 RGBA 上传,不经 binding)注入
  // 同一个闸门,与标准路径统一错峰;播放中的后续帧不过闸。
  NativeAnimatedImageProvider.firstFrameGate = ImageDecodeGate.run;

  // FlattenCache / ParagraphLayoutCache miss 的成本上报 span 账单
  // (flat:/tlay: 前缀,与 parse:/lay:/pnt: 同一管道;监控关闭时
  // noteSpan 空操作)。tlay:miss 大量出现 = 直绘布局缓存失效异常。
  FlattenCache.profileHook = (micros) {
    FrameJankMonitor.noteSpan('flat:miss', micros);
  };
  ParagraphLayoutCache.profileHook = (micros) {
    FrameJankMonitor.noteSpan('tlay:miss', micros);
  };

  // 触摸重采样已定案关闭(回归框架默认 false)。曾为治"120Hz 触摸 ×
  // 60Hz 显示"的滚动微抖开启(96a94f1),但 SDK 的重采样偏移是按 60Hz
  // 最坏情况校准的固定 -38ms(gestures/binding.dart _defaultSamplingOffset,
  // 不随刷新率缩放),高刷设备上触摸位置年龄 ≈46ms(≈5.5 帧),延迟代价
  // 远超平滑收益——这正是"比原生/其他 Flutter 应用不跟手"的主导项。
  // 微抖若在低触摸采样率机型复发,回滚方式:
  //   GestureBinding.instance.resamplingEnabled = true;
  //   GestureBinding.instance.samplingOffset = const Duration(milliseconds: -15);
  // (offset 按实际刷新率换算,勿吃 -38 默认值。)

  // 掉帧监控:debug/profile 无条件启用;release 由"性能诊断"设置开关
  // 控制(见下方 prefs 读取处)。Logcat 过滤 "JANK",或在设置 → 性能诊断
  // 页内直接查看与导出。不要用开着 DevTools Performance 页的体感判断
  // 卡顿(观察者效应)。
  if (!kReleaseMode) {
    FrameJankMonitor.start();
  }

  // Widget 级 build profiling 会为每次 build 写 Timeline 事件,对多楼层
  // 首建场景有明显观察者效应。默认关闭;需要深度归因时通过
  // --dart-define=FLUXDO_PROFILE_WIDGET_BUILDS=true 临时开启。
  const profileWidgetBuilds = bool.fromEnvironment(
    'FLUXDO_PROFILE_WIDGET_BUILDS',
  );
  if (!kReleaseMode && profileWidgetBuilds) {
    debugProfileBuildsEnabled = true;
  }

  // Release 模式下禁用 debugPrint 输出：全项目有数百处 debugPrint 调试输出，
  // 它们在 release 下默认仍会写 logcat/console，徒增 I/O 开销。
  // 需要持久化的日志统一走 AppLogger（落盘到统一 JSONL）。
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Flutter ImageCache 默认 100 MB / 1000 项。两个上限任一超过就 LRU evict。
  //
  // sticker / emoji 场景非常吃缓存:用户订阅 10+ 个表情包 group(每 group
  // 100-300 张)+ Discourse 自带几千个 emoji + 头像 + 贴内图,加起来很容易
  // 超过 5000 项,触发 LRU evict 后滚回去就要重新解码,用户感知卡顿。
  //
  // 256 MB / 30000 项:emoji thumbnail(64px)~16 KB、sticker thumbnail
  // (160px)~100 KB,256 MB 足够装下"全部 emoji + 几个 sticker group +
  // 当前贴图"。之前调过 800 MB,但中端 Android 机上内存压力换来系统级
  // GC / LMK 卡顿,得不偿失 —— 磁盘 PNG 缩略图缓存命中本来就是毫秒级,
  // evict 的重解成本远比内存压力的代价低。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 30000;

  // 启用 Edge-to-Edge 模式（小白条沉浸式）
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // 初始化语法高亮服务（预热 Isolate Worker 和字体）
  HighlighterService.instance.initialize(); // 不需要 await，后台初始化

  // 初始化本地通知服务（请求权限）
  LocalNotificationService().initialize(); // 不需要 await，后台初始化

  // Android：临时关闭 WebView DevTools 调试，停用原生 CDP 链路
  if (Platform.isAndroid) {
    InAppWebViewController.setWebContentsDebuggingEnabled(false);
  }

  // 阶段 1：并行执行所有不相互依赖的初始化
  final futures = <Future<dynamic>>[
    SharedPreferences.getInstance(),
    AppConstants.initUserAgent(),
    LogWriter.init(),
    ProxyCertificate.initialize(),
    // Windows 深链协议注册(discourse:// / fluxdo://):写 HKCU 免管理员,
    // 幂等,失败不阻塞启动。其他平台由清单/plist 声明,此调用为 no-op。
    if (Platform.isWindows) ensureWindowsProtocolsRegistered(),
    CookieJarService().initialize(),
    CsrfTokenService().init(),
    BackgroundNotificationService().initialize(),
    TimeUtils.initialize(),
    // 把 compat polyfill asset 读到内存，让 WebView 同步 getter 直接拿。
    // 失败不阻塞启动，仅影响老 WebView 兼容性。
    WebViewSettings.preloadPolyfill(),
  ];
  // 桌面平台初始化 window_manager 和 flutter_acrylic
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    futures.add(windowManager.ensureInitialized());
    futures.add(acrylic.Window.initialize());
  }
  final results = await Future.wait(futures);
  final prefs = results[0] as SharedPreferences;
  await AuthIssueNoticeService.instance.initialize(prefs);

  // release 下按设置开关启用性能监控(debug/profile 已在上方无条件启用)
  if (kReleaseMode && (prefs.getBool(FrameJankMonitor.prefKey) ?? false)) {
    FrameJankMonitor.start();
  }

  // v0.4.0: 注册 Cookie 引擎 DevTools service extensions (仅 debug/profile 模式)
  // 设计依据: docs/cookie-sync-design-v0.4.0.md §11.4
  CookieDevtoolsExtension.instance.register();

  // v0.4.0 Phase B: 启动 WV cookie store 外部变化观察
  // Apple 平台依赖 native WKHTTPCookieStoreObserver 自动触发,
  // Android 由 WV onLoadStop 等 hook 主动调 notifyExternalChange()。
  CookieStoreObserver.instance.attach();

  // 桌面平台：三端 runner 均隐藏启动（macOS 在 MainFlutterWindow 首次
  // order 时隐藏，Windows/Linux 由 runner 创建隐藏窗口），正常冷启动都
  // 走下方 else 分支：首帧光栅化后恢复窗口状态再显示，避免默认位置闪烁。
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await acrylic.Window.setEffect(
      effect: Platform.isMacOS
          ? acrylic.WindowEffect.sidebar
          : Platform.isWindows
          ? acrylic.WindowEffect.mica
          : acrylic.WindowEffect.disabled,
    );
    final isVisible = await windowManager.isVisible();
    await windowManager.setPreventClose(true);
    // 立即开始监听窗口事件，确保在 OnboardingPage/PreheatGate 等
    // MainPage 尚未挂载的阶段也能正常响应窗口关闭
    WindowStateService.instance.startListening();
    if (isVisible) {
      // 窗口已可见（热重启，或原生隐藏启动未生效的兜底路径）：
      // macOS 走 restore() 读取并应用保存的窗口状态——attach() 只刷新
      // 最大化缓存不读状态文件，曾导致 macOS 冷启动永远回到 XIB 默认
      // 位置；Windows/Linux 可见说明状态已恢复过，attach 即可。
      if (Platform.isMacOS) {
        await WindowStateService.instance.restore(prefs);
      } else {
        await WindowStateService.instance.attach(prefs);
      }
      if (Platform.isLinux) {
        await windowManager.focus();
      }
    } else {
      // 冷启动：窗口保持隐藏，推迟到 Flutter 首帧光栅化后再恢复位置并显示，
      // 避免 main() 后续初始化（迁移/网络栈/rhttp 等）期间露出空白窗口。
      // Future.any 兜底：极端情况下首帧迟迟未到时也要把窗口显示出来。
      unawaited(() async {
        await Future.any([
          WidgetsBinding.instance.waitUntilFirstFrameRasterized,
          Future.delayed(const Duration(seconds: 3)),
        ]);
        await windowManager.waitUntilReadyToShow(null, () async {
          await WindowStateService.instance.restore(prefs);
          if (Platform.isLinux) {
            await windowManager.focus();
          }
        });
      }());
    }
  }

  // 数据迁移：在所有依赖 prefs 的网络相关服务启动之前执行
  await MigrationService.runAll(prefs);

  // 阶段 2：依赖 prefs 的步骤并行
  final crashlyticsEnabled = prefs.getBool('pref_crashlytics') ?? true;
  final developerMode = prefs.getBool('developer_mode') ?? false;
  CfChallengeLogger.setEnabled(developerMode);
  // 开发者模式下 debug 级日志落盘（高频追踪信息）
  AppLogger.setVerbose(developerMode);
  await Future.wait([
    CronetFallbackService.instance.initialize(prefs),
    ProxySettingsService.instance.initialize(prefs),
    if (Platform.isAndroid)
      MethodChannel(
        'com.github.lingyan000.fluxdo/crashlytics',
      ).invokeMethod('setCrashlyticsEnabled', {'enabled': crashlyticsEnabled}),
  ]);
  // rhttp (Rust reqwest) 初始化：在 ProxySettingsService 之后、NetworkSettingsService 之前
  await RhttpSettingsService.instance.initialize(prefs);
  // WebView 适配器设置
  await WebViewAdapterSettingsService.instance.initialize(prefs);
  // Eruda 调试控制台开关 (默认关)
  await ErudaSettingsService.instance.initialize(prefs);
  try {
    final rhttp = await Future.any([
      _initRhttp(),
      Future.delayed(const Duration(seconds: 5), () => false),
    ]);
    if (rhttp != true) {
      debugPrint('[rhttp] 初始化超时或失败');
      await RhttpSettingsService.instance.forceDisable();
    }
  } catch (e) {
    debugPrint('[rhttp] 初始化异常: $e');
    await RhttpSettingsService.instance.forceDisable();
  }

  // Windows 固定系统代理必须先于本地 DoH/WebView 网关读取，网关才能按
  // 「应用代理 > 系统代理 > 直连」选择首次启动的上游出口。
  if (Platform.isWindows) {
    SystemProxyService.instance.start();
  }
  await NetworkSettingsService.instance.initialize(prefs);
  // WindowsWebViewEnvironmentService 必须等 NetworkSettingsService 把本次
  // 会话真正要用的代理端口定下来之后再创建 Environment。之前放在最早那批
  // 并行初始化里,等的是"猜的"8s 超时——NetworkSettingsService 前面还排
  // 着 rhttp(自己就留了最多 5s 预算)等好几个服务,8s 经常等不到真实端口
  // 就用旧端口摆烂,导致 WebView2 全程连着一个不存在的代理、CF 验证怎么
  // 也过不去。现在严格排在 NetworkSettingsService 完全初始化(本地代理
  // 已经启动、setProxy() 已经真正调用过)之后再建,proxyDecision 这时
  // 早就 complete 了,创建时直接读到确定值,不用再赌超时。
  if (Platform.isWindows) {
    await WindowsWebViewEnvironmentService.instance.initialize();
  }
  VpnAutoToggleService.instance.initialize(prefs);
  try {
    final initialConnectivity =
        await ConnectivityService.safeCheckConnectivity();
    await VpnAutoToggleService.instance.syncInitialState(initialConnectivity);
  } catch (e) {
    debugPrint('[Main] 初始 VPN 状态同步失败: $e');
  }

  // 必须等 DoH / 系统代理 / VPN 自动切换全部落定后再预热 Cookie。
  // Windows 设置本地代理会销毁并重建 WebView2 Environment；若提前预热，
  // 任务会继续操作已销毁的旧环境并反复重试，显著拉长开屏时间。
  BrowserTrustCoordinator.instance.prepareStartup(reason: 'startup');

  // 初始化下载服务（依赖网络栈已就绪）
  DownloadService().initialize();

  // 冷启动自动清除图片缓存（如果用户开启了该选项）
  if (prefs.getBool('pref_clear_cache_on_exit') == true) {
    BlobImageCache.clearAll()
        .then((_) => CacheSizeService.deleteImageCacheDirs())
        .ignore();
  }

  // 应用竖屏锁定设置（仅移动端）
  if (Platform.isIOS || Platform.isAndroid) {
    final portraitLock = prefs.getBool('pref_portrait_lock') ?? false;
    if (portraitLock) {
      PreferencesNotifier.isPortraitLocked = true;
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  // 应用 Android 屏幕刷新率偏好（不阻塞启动）
  if (Platform.isAndroid) {
    unawaited(_applyAndroidDisplayMode(prefs));
  }

  // 提前触发预加载数据请求，与 runApp 并行执行。
  // PreheatGate 中的 ensurePreloaded() 会复用这个已在进行的请求。
  unawaited(
    BrowserTrustCoordinator.instance
        .ensurePreloaded(reason: 'startup')
        .catchError((Object _) {}),
  );

  // 记录应用启动日志
  LogWriter.instance.write({
    'timestamp': DateTime.now().toIso8601String(),
    'level': 'info',
    'type': 'lifecycle',
    'event': 'app_start',
    'message': '应用启动',
  });

  // 启动后台维护:迁移 trash 目录清扫(v7/v8 rename 出来的待删区)+
  // blob 缓存过期扫描(24h 节流)。都在首帧渲染完 + 60s 空闲后跑,
  // 重活全在 Isolate.run,不与启动/首屏抢资源。
  unawaited(() async {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    await Future.delayed(const Duration(seconds: 60));
    await MigrationService.purgeTrash();
    await BlobImageCache.sweep(prefs);
  }());

  // 注入 hashtag 药丸的图标解析与点击导航(fluxdo_render 注入点)
  installHashtagHandlers();

  // 折叠块(details/callout)展开动画帧武装滚动锚定哨兵:center 双向
  // 列表的 reverse 半场里子项向上生长,不锚定的话点击展开会把头部顶出
  // 视口(视觉 = 跳到内容底部)。forward 半场锚位移为 0,修正自动
  // no-op,"展开再收起逐像素复原"不受影响。
  FoldShiftHook.onFrame = AnchorGuardSliver.arm;

  // 注入 AI 模型管理包的消息提示实现
  AiToastDelegate.configure((message, {type = AiToastType.info}) {
    switch (type) {
      case AiToastType.success:
        ToastService.showSuccess(message);
      case AiToastType.error:
        ToastService.showError(message);
      case AiToastType.info:
        ToastService.showInfo(message);
    }
  });

  // 注入自定义加载指示器
  AiToastDelegate.configureLoading(({color, size = 48}) {
    return LoadingSpinner(color: color, size: size);
  });

  // 根据当前语言配置 AI 模型管理包的语言
  final savedLocale = prefs.getString('pref_locale');
  if (savedLocale != null && savedLocale != 'system') {
    final parts = savedLocale.split('_');
    AiL10n.configureLocale(
      Locale(parts[0], parts.length > 1 ? parts[1] : null),
    );
    await LocaleSettings.setLocaleRaw(savedLocale);
  } else {
    await LocaleSettings.useDeviceLocale();
  }

  // 过滤 Flutter 框架已知 bug（https://github.com/flutter/flutter/issues/115787）
  // SelectionArea + CustomScrollView 拖选时触发的断言错误，仅 debug 模式出现
  bool filterKnownFrameworkBugs(Report report) {
    final error = report.error;
    if (error is AssertionError &&
        error.message?.toString().contains(
              'Drag target size is larger than scrollable size',
            ) ==
            true) {
      return false;
    }
    return true;
  }

  // 配置 Catcher2 全局异常捕获
  final debugConfig = Catcher2Options(
    SilentReportMode(),
    [ConsoleHandler(), JsonFileHandler()],
    handlerTimeout: 10000,
    filterFunction: filterKnownFrameworkBugs,
    logger: FilteredCatcherLogger(),
  );
  final releaseConfig = Catcher2Options(
    SilentReportMode(),
    [JsonFileHandler()],
    handlerTimeout: 10000,
    filterFunction: filterKnownFrameworkBugs,
    logger: FilteredCatcherLogger(),
  );

  // 把 ai_model_manager 包内的诊断日志桥接到主应用 AppLogger,
  // 让 release 模式下也能写到日志文件供反馈用户提交排查。
  AiPackageLogger.handler = (level, tag, message) {
    switch (level) {
      case 'error':
        AppLogger.error(message, tag: tag);
      case 'warning':
        AppLogger.warning(message, tag: tag);
      default:
        AppLogger.info(message, tag: tag);
    }
  };

  Catcher2(
    navigatorKey: navigatorKey,
    rootWidget: ProviderScope(
      // 禁用 Riverpod 3 默认的自动重试机制
      // 默认会对所有失败的异步 provider 指数退避重试 10 次，
      // 在网络不通时会造成大量无意义的重复请求
      retry: (_, _) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        aiSharedPreferencesProvider.overrideWithValue(prefs),
        aiDioAdapterFactoryProvider.overrideWithValue(
          createExternalHttpAdapter,
        ),
        // 内置 PromptPreset 列表：在 override 函数内 watch localeProvider，
        // locale 切换时整个 builtInPresetsProvider 重建 → 下游
        // promptPresetListProvider 的 StateNotifier 重新构造 → preset i18n
        // 文本随之刷新。
        builtInPresetsProvider.overrideWith((ref) {
          ref.watch(localeProvider);
          return BuiltInPresetsFactory.create();
        }),
      ],
      child: const MainApp(),
    ),
    debugConfig: debugConfig,
    releaseConfig: releaseConfig,
    profileConfig: releaseConfig,
    enableLogger: kDebugMode,
  );
}

/// 只给 textTheme/primaryTextTheme 注入中文 fallback，保留 ThemeData 原本的
/// fontFamily 与 weight 配置（避免覆盖 Android OEM 字体导致视觉变粗）。
ThemeData _withChineseFallback(ThemeData base) {
  final fallback = SystemChineseFont.fontFamilyFallback;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: fallback),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamilyFallback: fallback),
  );
}

/// Material Symbols 全局轴默认：fill=0 走线框，weight/grade/opticalSize
/// 给出与现有视觉匹配的中性值。状态类图标需在使用处显式传 `fill: 1`。
IconThemeData _appIconTheme(Color color) => IconThemeData(
  color: color,
  size: 24,
  fill: 0,
  weight: 400,
  grade: 0,
  opticalSize: 24,
);

/// 页面转场:框架在 Android 的默认(PredictiveBack,常规导航兜底到
/// FadeForwards)是入场/离场两页各套一个整页 FadeTransition —— Impeller
/// 下每个半透明整页 = 一次全屏 saveLayer 离屏,且 Impeller 没有 Skia 的
/// raster cache,转场每帧都在重光栅化两个页面。详情页↔列表页这种复杂
/// 内容在 120Hz(8.3ms 预算)下每帧 raster 10~50ms,整段转场连串掉帧
/// (诊断日志里 NAV 后成串的纯 raster 大帧,即"一般场景动不动抽")。
/// 统一换 Cupertino 滑动转场:纯平移 + 边缘阴影,零整页 saveLayer。
/// Android 用拷贝改造的 PredictiveBackCupertinoPageTransitionsBuilder:
/// 系统预测返回手势保留原生 shared-element 预览,其余导航(push/按钮
/// 返回)降级到 Cupertino 而非官方硬编码的 FadeForwards。
const _pageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: PredictiveBackCupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
  },
);

/// 「全屏侧滑返回」开启时的转场:移动端在原转场树里追加整页 iOS 式
/// 返回手势(转场视觉不变,仅扩大手势探测区);桌面端保持边缘手势。
const _fullscreenSwipePageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: FullscreenSwipeBackTransitionsBuilder(
      PredictiveBackCupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.iOS: FullscreenSwipeBackTransitionsBuilder(
      CupertinoPageTransitionsBuilder(),
    ),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
  },
);

/// M3E 按钮按压形变,参数对照 Compose ButtonSmallTokens 标准:
/// ContainerShapeRound = CornerFull(Stadium)→ PressedContainerShape =
/// CornerSmall(8dp)。形状插值由 Material 内部 ImplicitlyAnimatedWidget
/// 完成,theme 注入全局生效;时长对齐规格用的 DefaultEffects 弹簧
/// (spring(1.0, 1600) 收敛 ≈180ms,规格注释明确"不允许过冲",
/// Material 的 fastOutSlowIn 曲线正好同为无过冲缓动)。
ButtonStyle _m3ePressedShapeStyle() => ButtonStyle(
  animationDuration: const Duration(milliseconds: 180),
  shape: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.pressed)
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
        : const StadiumBorder(),
  ),
);

/// IconButton 版本:在按压形变之上叠加 selected 态形状(Compose
/// IconToggleButtonShapes 语义:pressed > checked > 默认)。选中的
/// 切换图标按钮从全圆变小圆角方,给 36 处 isSelected 调用点免费的
/// M3E 切换标志动效;时长同 DefaultEffects。
ButtonStyle _m3eIconButtonShapeStyle() => ButtonStyle(
  animationDuration: const Duration(milliseconds: 180),
  shape: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.pressed)) {
      return RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    }
    if (states.contains(WidgetState.selected)) {
      return RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    }
    return const StadiumBorder();
  }),
);

/// light/dark 共用的 ThemeData 装配(两侧必须对称,尤其 M3eFlags ——
/// ThemeData.lerp 对单边缺失的 extension 不插值而是瞬时并入)。
ThemeData _buildAppTheme(
  ColorScheme scheme,
  ThemeState themeState, {
  required bool fullscreenSwipeBack,
  required bool transparent,
}) {
  final m3e = themeState.m3eEnabled;
  final buttonStyle = m3e ? _m3ePressedShapeStyle() : null;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: themeState.fontFamilyName,
    // 透明模式：脚手架让出背景，由根背景层的用户图片透出
    scaffoldBackgroundColor: transparent ? Colors.transparent : null,
    pageTransitionsTheme: fullscreenSwipeBack
        ? _fullscreenSwipePageTransitionsTheme
        : _pageTransitionsTheme,
    iconTheme: _appIconTheme(scheme.onSurface),
    primaryIconTheme: _appIconTheme(scheme.onPrimary),
    extensions: [M3eFlags(enabled: m3e)],
    // year2023: false 启用进度条/滑块的 M3E 翻新(圆角端点/track gap/
    // stop indicator/16dp 滑轨+竖条 thumb)。字段虽标记 deprecated,但
    // trackGap 等新样式只由它驱动,官方 M3E 独立包落地前只能走这里。
    // circularTrackPadding 归零:新样式默认 4dp 内边距会把存量
    // SizedBox(20) 小圈的可画区吃掉 8dp。
    // ignore: deprecated_member_use
    progressIndicatorTheme: ProgressIndicatorThemeData(
      // ignore: deprecated_member_use
      year2023: !m3e,
      circularTrackPadding: EdgeInsets.zero,
    ),
    // ignore: deprecated_member_use
    sliderTheme: SliderThemeData(year2023: !m3e),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    iconButtonTheme: IconButtonThemeData(
      style: m3e ? _m3eIconButtonShapeStyle() : null,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 3,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
    ),
  );
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final fullscreenSwipeBack = ref.watch(
      preferencesProvider.select((p) => p.fullscreenSwipeBack),
    );
    ref.listen<Locale?>(localeProvider, (_, next) {
      unawaited(_syncSlangLocale(next));
    });

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // 把系统动态色原始 primary 存到 ThemeState 中；
        // 明暗两套齐全才采用，缺一侧回退种子色（沿用原逻辑）
        final rawDynamicPrimary = lightDynamic != null && darkDynamic != null
            ? lightDynamic.primary
            : null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(themeProvider.notifier).setDynamicPrimary(rawDynamicPrimary);
        });

        // 默认走完整 fromSeed 方案（表面带种子色相）；中性/纯黑/透明
        // 开关由 ThemeResolver 切换到"强调色 × 中性层"的合成路径。
        // 动态色路径只取系统动态色 primary 当种子，不用 OEM 原始 scheme。
        final resolvedTheme = ThemeResolver.resolve(
          mode: themeState.mode,
          neutral: themeState.neutralEnabled,
          black: themeState.blackEnabled,
          transparent: themeState.isTransparentActive,
          seed: themeState.effectiveSeedColor,
          variant: themeState.schemeVariant,
        );
        final lightScheme = resolvedTheme.light;
        final darkScheme = resolvedTheme.dark;

        return TranslationProvider(
          child: Builder(
            builder: (context) => MaterialApp(
              navigatorKey: navigatorKey,
              // JankNavObserver 给 [JANK] 日志加导航归因(debug/profile 观测用)
              // KeyboardFocusGuard 压掉浮层关闭后键盘自弹(移动端)
              // EscFallbackObserver 登记全屏页,桌面 ESC 路由级自动兜底
              navigatorObservers: [
                appRouteObserver,
                keyboardFocusGuard,
                JankNavObserver(),
                EscFallbackObserver(),
              ],
              title: 'FluxDO',
              locale: TranslationProvider.of(context).flutterLocale,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocaleUtils.supportedLocales,
              themeMode: resolvedTheme.mode,
              // 仅注入 fontFamilyFallback，不替换 textTheme，避免覆盖 Android OEM
              // 系统字体（chinese_font_library 自带的 ThemeData.useSystemChineseFont
              // 会强制改为 Roboto，导致字体显得比之前粗）。
              theme: _withChineseFallback(
                _buildAppTheme(
                  lightScheme,
                  themeState,
                  fullscreenSwipeBack: fullscreenSwipeBack,
                  transparent: resolvedTheme.transparent,
                ),
              ),
              darkTheme: _withChineseFallback(
                _buildAppTheme(
                  darkScheme,
                  themeState,
                  fullscreenSwipeBack: fullscreenSwipeBack,
                  transparent: resolvedTheme.transparent,
                ),
              ),
              builder: (context, child) {
                final brightness = Theme.of(context).brightness;
                final iconBrightness = brightness == Brightness.light
                    ? Brightness.dark
                    : Brightness.light;
                // 桌面平台：跟随应用主题明暗切换窗口效果
                if (Platform.isMacOS ||
                    Platform.isWindows ||
                    Platform.isLinux) {
                  final isDark = brightness == Brightness.dark;
                  acrylic.Window.setEffect(
                    // 透明模式下禁用系统窗口效果，避免桌面壁纸
                    // 与用户背景图双重透出造成视觉混乱
                    effect: resolvedTheme.transparent
                        ? acrylic.WindowEffect.disabled
                        : Platform.isMacOS
                        ? acrylic.WindowEffect.sidebar
                        : Platform.isWindows
                        ? acrylic.WindowEffect.mica
                        : acrylic.WindowEffect.disabled,
                    dark: isDark,
                  );
                  if (Platform.isMacOS) {
                    acrylic.Window.overrideMacOSBrightness(dark: isDark);
                  }
                }
                Widget result = AnnotatedRegion<SystemUiOverlayStyle>(
                  value: SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    statusBarIconBrightness: iconBrightness,
                    systemNavigationBarIconBrightness: iconBrightness,
                    systemNavigationBarColor: Colors.transparent,
                    // Android 28 上 dividerColor 不能完全透明，用 withAlpha(1) 兼容
                    systemNavigationBarDividerColor: Colors.transparent
                        .withAlpha(1),
                    // 关闭系统自动 scrim，实现完全沉浸
                    systemNavigationBarContrastEnforced: false,
                  ),
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      // 透明模式的用户背景层，垫在 Navigator 之下
                      if (resolvedTheme.transparent)
                        Positioned.fill(
                          child: AppBackgroundLayer(
                            background: themeState.background,
                          ),
                        ),
                      child!,
                      const ReadLaterBubble(),
                    ],
                  ),
                );

                result = Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    UserPresenceService().markUserActivity();
                    // 鼠标侧键返回（第 4 按钮，bit flag 0x08）
                    if (PlatformUtils.isDesktop && event.buttons & 0x08 != 0) {
                      navigatorKey.currentState?.maybePop();
                    }
                  },
                  onPointerMove: (_) =>
                      UserPresenceService().markUserActivity(),
                  onPointerSignal: (_) =>
                      UserPresenceService().markUserActivity(),
                  child: result,
                );

                // 全局滚动繁忙信号:后台维护任务(WebView cookie 轮询等
                // 平台主线程 IPC)据此在滚动中让路,见 ScrollBusySignal
                result = NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollUpdateNotification ||
                        notification is ScrollStartNotification) {
                      ScrollBusySignal.touch();
                    }
                    return false;
                  },
                  child: result,
                );

                // 桌面端：全局键盘快捷键（HardwareKeyboard）
                if (PlatformUtils.isDesktop) {
                  result = KeyboardShortcutHandler(
                    navigatorKey: navigatorKey,
                    child: result,
                  );
                }

                // 修复小米 HyperOS 小窗(freeform)页面空白只剩底栏:
                // 引擎(API 35+)把 viewPaddingTop 抬到 WindowInsets captionBar
                // boundingRect.bottom(flutter/engine#54294),HyperOS 小窗上报的
                // rect 坐标系错误,padding.top 可达 600+(flutter/flutter#161086),
                // SafeArea/AppBar 内容被整体推出可视区。top padding 超过窗口
                // 高度 30% 必为异常值(真实状态栏 <100dp),钳回合理值。
                if (Platform.isAndroid) {
                  final mq = MediaQuery.of(context);
                  final threshold = mq.size.height * 0.3;
                  final padTop = mq.padding.top;
                  final viewTop = mq.viewPadding.top;
                  if (padTop > threshold || viewTop > threshold) {
                    result = MediaQuery(
                      data: mq.copyWith(
                        padding: mq.padding.copyWith(
                          top: padTop > threshold ? 20.0 : padTop,
                        ),
                        viewPadding: mq.viewPadding.copyWith(
                          top: viewTop > threshold ? 20.0 : viewTop,
                        ),
                      ),
                      child: result,
                    );
                  }
                }

                return result;
              },
              home: const OnboardingGate(child: PreheatGate(child: MainPage())),
            ),
          ),
        );
      },
    );
  }
}

Future<void> _syncSlangLocale(Locale? locale) async {
  if (locale == null) {
    await LocaleSettings.useDeviceLocale();
    return;
  }

  final rawLocale = locale.countryCode?.isNotEmpty == true
      ? '${locale.languageCode}_${locale.countryCode}'
      : locale.languageCode;
  await LocaleSettings.setLocaleRaw(rawLocale);
}

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

enum _AuthErrorDialogAction { confirm, clearData }

class _MainPageState extends ConsumerState<MainPage>
    with WidgetsBindingObserver {
  // 当前活跃 tab 按稳定 id 跟踪，不用 pageEntries 数字下标：登录态变化
  // 会增删 requiresLogin 的 entry（退出登录即触发过滤、重新登录后恢复），
  // 下标会漂移指向错误页面（曾表现为退出/重新登录后底栏跳到第二个）。
  String _currentEntryId = NavEntryIds.home;
  ProviderSubscription<AsyncValue<String>>? _authErrorSub;
  ProviderSubscription<AsyncValue<void>>? _authStateSub;
  ProviderSubscription<AsyncValue<User?>>? _currentUserSub;
  ProviderSubscription<void>? _messageBusSub;
  ProviderSubscription<void>? _notificationChannelSub;
  ProviderSubscription<void>? _notificationAlertChannelSub;
  ProviderSubscription<void>? _chatAlertChannelSub;
  ProviderSubscription<AsyncValue<bool>>? _connectivitySub;
  bool _messageBusInitialized = false;
  int? _lastTappedIndex;
  DateTime? _lastTapTime;
  Timer? _pendingSingleTap;
  List<NavEntry> _lastResolvedEntries = const [];
  Timer? _resumeDebounceTimer;
  final BackExitGuard _backExitGuard = BackExitGuard();
  bool _clipboardCheckInFlight = false;

  // 不能是 const，需要传入 isActive

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UserPresenceService().setForeground(true, countAsActivity: true);
    HardwareKeyboard.instance.addHandler(_handlePresenceKeyEvent);
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      WindowStateService.instance.startListening();
    }

    // 设置导航 context（用于 CF 验证弹窗）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 标记应用已就绪（MainPage 在 PreheatGate 之后才挂载）
      ref.read(appReadyProvider.notifier).state = true;
      BrowserTrustCoordinator.instance.setNavigatorContext(context);

      // 初始化 Deep Link 服务
      DeepLinkService.instance.initialize(context);
      unawaited(
        _runStartupUiTasks().catchError((Object e, StackTrace s) {
          debugPrint('[MainPage] 启动 UI 任务失败: $e\n$s');
        }),
      );
    });
    // 监听登录失效事件
    _authErrorSub = ref.listenManual<AsyncValue<String>>(authErrorProvider, (
      _,
      next,
    ) {
      next.whenData((message) => _handleAuthError(message));
    });

    // 初始化连通性检测服务
    ConnectivityService().init();

    // 全局监听连接状态变化，弹 Toast 通知用户
    _connectivitySub = ref.listenManual<AsyncValue<bool>>(isConnectedProvider, (
      prev,
      next,
    ) {
      final wasConnected = prev?.value ?? true;
      final isNow = next.value;
      if (isNow == false && wasConnected) {
        ToastService.showError(S.current.toast_networkDisconnected);
      } else if (isNow == true && prev?.value == false) {
        ToastService.showSuccess(S.current.toast_networkRestored);
      }
    });

    // 提前捕获 container:登录成功广播可能落在本元素 deactivate/重挂载
    // 窗口内,届时 containerOf(context) 会抛错把刷新链掐死(登录后无
    // 登录态)。container 与根 ProviderScope 同生命周期,不受元素影响。
    final appContainer = ProviderScope.containerOf(context, listen: false);
    _authStateSub = ref.listenManual<AsyncValue<void>>(authStateProvider, (
      _,
      next,
    ) {
      next.whenData((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          AppStateRefresher.refreshAll(appContainer);
        });
      });
    });
    _currentUserSub = ref.listenManual<AsyncValue<User?>>(currentUserProvider, (
      previous,
      next,
    ) {
      final previousUser = previous?.value;
      final user = next.value;
      if (previousUser == null && user != null) {
        BrowserTrustCoordinator.instance.startClearanceRefresh(
          reason: 'current_user_ready',
        );
      }
      if (user != null && !_messageBusInitialized) {
        _messageBusInitialized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _messageBusSub?.close();
          _messageBusSub = ref.listenManual<void>(
            messageBusInitProvider,
            (_, _) {},
          );
          _notificationChannelSub?.close();
          _notificationChannelSub = ref.listenManual<void>(
            notificationChannelProvider,
            (_, _) {},
          );
          _notificationAlertChannelSub?.close();
          _notificationAlertChannelSub = ref.listenManual<void>(
            notificationAlertChannelProvider,
            (_, _) {},
          );
          _chatAlertChannelSub?.close();
          _chatAlertChannelSub = ref.listenManual<void>(
            chatNotificationAlertProvider,
            (_, _) {},
          );
        });
      } else if (user == null) {
        _messageBusInitialized = false;
        _messageBusSub?.close();
        _messageBusSub = null;
        _notificationChannelSub?.close();
        _notificationChannelSub = null;
        _notificationAlertChannelSub?.close();
        _notificationAlertChannelSub = null;
        _chatAlertChannelSub?.close();
        _chatAlertChannelSub = null;
      }
    }, fireImmediately: true);
  }

  Future<void> _autoCheckUpdate() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final updateService = UpdateService(prefs: prefs);
    await UpdateCheckerHelper.checkUpdateOnStartup(context, updateService);
  }

  Future<void> _runStartupUiTasks() async {
    // 启动弹窗先于剪贴板提示，避免 SnackBar 被弹窗遮挡后仍被记为已提示。
    await _autoCheckUpdate();
    if (!mounted) return;

    // 一次性数据收集告知（仅 Android）
    if (Platform.isAndroid) {
      await _showCrashlyticsNotice();
      if (!mounted) return;
    }

    await _checkClipboardTopicLink();
  }

  Future<void> _showCrashlyticsNotice() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool('crashlytics_notice_shown') ?? false) return;
    await prefs.setBool('crashlytics_notice_shown', true);
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(S.current.preferences_enableCrashlyticsTitle),
        content: Text(S.current.preferences_enableCrashlyticsContent),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _onDestinationSelected(int index) {
    if (index < 0 || index >= _lastResolvedEntries.length) return;
    final entry = _lastResolvedEntries[index];

    // 非 page kind：直接触发对应回调，不改 _currentEntryId
    if (entry.kind == NavEntryKind.panel) {
      _cancelPendingSingleTap();
      entry.onPanelTap?.call(context, ref);
      return;
    }
    if (entry.kind == NavEntryKind.action) {
      _cancelPendingSingleTap();
      entry.onAction?.call(context, ref);
      return;
    }

    // page kind（kind 已确认，这里仅做防御性映射校验）
    if (_pageIndexOfBottom(index) < 0) return;

    final now = DateTime.now();

    // 切换 tab：只记录时间戳，不走手势分流
    if (entry.id != _currentEntryId) {
      _cancelPendingSingleTap();
      _lastTappedIndex = index;
      _lastTapTime = now;
      ref.read(barVisibilityProvider.notifier).state = 1.0;
      setState(() => _currentEntryId = entry.id);
      return;
    }

    // 点击已选中 tab（主要走侧栏路径；底栏在 AdaptiveBottomNavigation 内已自行分流）
    final prefs = ref.read(preferencesProvider);
    final single = prefs.bottomSingleTapAction;
    final doubleAction = prefs.bottomDoubleTapAction;

    final hasSingle = single != NavTapAction.none;
    final hasDouble = doubleAction != NavTapAction.none;
    if (!hasSingle && !hasDouble) return;

    final id = entry.id;

    final isDoubleTap =
        hasDouble &&
        _lastTappedIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!).inMilliseconds < 300;

    if (isDoubleTap) {
      _cancelPendingSingleTap();
      final navAction = doubleAction.toNavAction();
      if (navAction != null) {
        ref.dispatchNavAction(id, navAction);
      }
      _lastTappedIndex = null;
      _lastTapTime = null;
      return;
    }

    _lastTappedIndex = index;
    _lastTapTime = now;

    if (!hasSingle) return;
    final navAction = single.toNavAction();
    if (navAction == null) return;

    if (hasDouble) {
      _cancelPendingSingleTap();
      _pendingSingleTap = Timer(const Duration(milliseconds: 300), () {
        _pendingSingleTap = null;
        if (!mounted) return;
        ref.dispatchNavAction(id, navAction);
        if (_lastTappedIndex == index) {
          _lastTappedIndex = null;
          _lastTapTime = null;
        }
      });
    } else {
      ref.dispatchNavAction(id, navAction);
    }
  }

  void _cancelPendingSingleTap() {
    _pendingSingleTap?.cancel();
    _pendingSingleTap = null;
  }

  /// 底栏 index 对应的 page 维度 index；不是 page kind 返回 -1
  int _pageIndexOfBottom(int bottomIndex) {
    int pageIdx = 0;
    for (int i = 0; i < _lastResolvedEntries.length; i++) {
      final e = _lastResolvedEntries[i];
      if (i == bottomIndex) {
        return e.kind == NavEntryKind.page ? pageIdx : -1;
      }
      if (e.kind == NavEntryKind.page) pageIdx++;
    }
    return -1;
  }

  @override
  void dispose() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      WindowStateService.instance.stopListening();
    }
    HardwareKeyboard.instance.removeHandler(_handlePresenceKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _resumeDebounceTimer?.cancel();
    _pendingSingleTap?.cancel();
    _authErrorSub?.close();
    _authStateSub?.close();
    _currentUserSub?.close();
    _messageBusSub?.close();
    _notificationChannelSub?.close();
    _notificationAlertChannelSub?.close();
    _chatAlertChannelSub?.close();
    _connectivitySub?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      UserPresenceService().setForeground(true, countAsActivity: true);
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      UserPresenceService().setForeground(false);
    }

    if (state == AppLifecycleState.hidden) {
      // hidden 比 paused 更早触发，在系统挂起 Dart isolate 之前启动前台服务
      // 取消待执行的 resume 操作（防止配置变更等假 resume）
      _resumeDebounceTimer?.cancel();
      _resumeDebounceTimer = null;
      _enterBackground();
      BrowserTrustCoordinator.instance.pauseForBackground();
    } else if (state == AppLifecycleState.resumed) {
      // 延迟执行，避免系统配置变更（主题切换等）触发的假 resume
      _resumeDebounceTimer?.cancel();
      _resumeDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        _resumeDebounceTimer = null;
        unawaited(_resumeFromBackground());
      });
    }
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    // 系统内存压力统一入口:iOS 内存警告 / Android onTrimMemory /
    // 金标联盟公平运行内存 TRIM 广播(FairMemoryReceiver 翻译成同一
    // memoryPressure 通道)。imageCache(最大头,256MB 上限)由框架
    // PaintingBinding.handleMemoryPressure 自清,这里补自建缓存:
    // - RenderParseCache:纯数据,清空安全;
    // - FlattenCache:引用计数设计,在用条目标 dead 延迟释放,安全;
    // - ParagraphLayoutCache 刻意不清:evictAll 会 dispose 在屏
    //   RenderObject 仍持有的 ui.Paragraph(paint 不重走 layout,
    //   仅 reassemble 全量重建场景安全),且量级仅数 MB 不值得冒险。
    RenderParseCache.clear();
    FlattenCache.evictAll();
    // 公平内存机制下持续增长会触达查杀线,先把监控现场落盘(未启用
    // 或无记录时内部直接返回,静默失败)。
    unawaited(FrameJankMonitor.persistSnapshot());
    debugPrint('[MainPage] 内存压力:已清理解析/flatten 缓存');
  }

  Future<void> _resumeFromBackground() async {
    // App 回到前台 — 停止后台保活 + 恢复所有频道 + 刷新通知。
    try {
      await BackgroundNotificationService().disable();
      MessageBusService().exitBackgroundMode();
      if (Platform.isIOS) {
        // iOS 后台轮询任务在独立 isolate 写 cookie 文件，回前台时重载
        // 磁盘值，避免主 isolate 用旧缓存覆盖后台轮换的 token
        CookieJarService().reloadPersistedCookies();
      }
      if (!mounted) return;
      ref.invalidate(notificationListProvider);
      // 检查 DOH 代理是否在后台期间失效，若失效则自动重启
      NetworkSettingsService.instance.ensureProxyAlive();
      // 回到前台时主动检查连通性（等同 Discourse 的 visibilitychange）
      unawaited(ConnectivityService().check());
      unawaited(_checkClipboardTopicLink());
    } catch (e) {
      debugPrint('[MainPage] 恢复前台失败: $e');
    } finally {
      BrowserTrustCoordinator.instance.resumeFromBackground(reason: 'resume');
    }
  }

  bool _handlePresenceKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      UserPresenceService().markUserActivity();
    }
    return false;
  }

  Future<void> _checkClipboardTopicLink() async {
    // 重入防护:启动和「假 resume」(系统配置变更等触发的
    // didChangeAppLifecycleState resumed)可能在短窗口内先后调用本方法
    // 两次,不加锁会各自读到同一个 candidate、各弹一次提示。
    if (_clipboardCheckInFlight) return;
    _clipboardCheckInFlight = true;
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final clipboardTopicLinkService = ClipboardTopicLinkService.instance;
      final candidate = await clipboardTopicLinkService.checkClipboard(
        enabled: ref.read(preferencesProvider).clipboardTopicLinkDetection,
        lastPromptedHash: prefs.getInt(
          ClipboardTopicLinkService.lastPromptedHashPrefsKey,
        ),
      );
      if (!mounted || candidate == null) return;

      // ToastService 而不是 ScaffoldMessenger:设置页宽屏下是主从双栏,
      // 两侧各有一个独立 Scaffold,ScaffoldMessenger 在这种多 Scaffold
      // 场景下会两边都弹一条——ToastService 是单例 OverlayEntry,不挂靠
      // 任何 Scaffold,天然只有一份。
      unawaited(
        clipboardTopicLinkService.markPrompted(candidate, prefs: prefs),
      );
      ToastService.show(
        context.l10n.preferences_clipboardTopicLink_detected,
        duration: const Duration(seconds: 8),
        actionLabel: context.l10n.preferences_clipboardTopicLink_open,
        // 宽屏且能解析成话题链接就进首页平行视界（选中 + 切 tab）；
        // 窄屏没有「写栈 → 推详情」的桥（同通知入口的窄屏问题），
        // 和解析失败一样退回深链通道全屏打开
        onAction: () {
          final topic = DiscourseUrlParser.parseTopic(candidate.uri.toString());
          if (topic != null &&
              MasterDetailLayout.canShowBothPanesFor(context)) {
            ref
                .read(selectedTopicProvider.notifier)
                .select(
                  topicId: topic.topicId,
                  initialTitle: topic.slug,
                  scrollToPostNumber: topic.postNumber,
                );
            ref.requestNavDestination(NavEntryIds.home);
          } else {
            DeepLinkService.instance.handleUri(candidate.uri);
          }
        },
      );
    } finally {
      _clipboardCheckInFlight = false;
    }
  }

  /// App 进入后台：先启动前台服务保活，再切换到只轮询通知频道
  Future<void> _enterBackground() async {
    // 清后台图片内存缓存按平台分派:
    // - 桌面端跳过——最小化即触发本回调,一次性并发销毁大量 GPU 贴图
    //   (SkImage_Ganesh/GrTextureProxy)疑撞 Skia disposal 问题
    //   (discourse_cache_manager.dart 里动图那块引用过的 Flutter
    //   #85831 同一类坑),聊天页同屏头像/emoji 最多最易踩中;桌面
    //   也不存在后台 OOM 击杀,清空只省一点驻留,不值得冒崩溃风险。
    // - 移动端保留——降后台驻留配合保活,降低 LMKD 击杀概率(被杀
    //   = 通知轮询没了);LMKD 不总先发 memory pressure,框架自清
    //   兜不住这个场景。
    if (!PlatformUtils.isDesktop) {
      PaintingBinding.instance.imageCache.clear();
    }

    // 诊断快照落盘:进程随后被杀时环形缓冲现场不再全丢(监控未启用
    // 或无记录时内部直接返回;静默失败,不干扰退后台路径)
    unawaited(FrameJankMonitor.persistSnapshot());

    try {
      final user = ref.read(currentUserProvider).value;
      if (user != null) {
        // 先启动前台服务，确保进程不被杀死
        await BackgroundNotificationService().enable(user.id);
      }
      // 服务就绪后再切换轮询模式
      MessageBusService().enterBackgroundMode();
    } catch (e) {
      // 自签名应用可能不支持 BGTaskScheduler，静默忽略
      debugPrint('[MainPage] 进入后台失败: $e');
    }
  }

  Future<void> _handleAuthError(String message) async {
    if (!mounted) return;

    final advice = AuthIssueNoticeService.instance
        .consumeLatestPassiveLogoutAdvice();
    final content = _buildAuthErrorDialogMessage(message, advice);

    final action = await showAppDialog<_AuthErrorDialogAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(S.current.auth_loginExpiredTitle),
        content: Text(content),
        actions: [
          if (advice.suggestClearData)
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _AuthErrorDialogAction.clearData),
              child: Text(S.current.auth_clearDataAction),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _AuthErrorDialogAction.confirm),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );

    if (mounted) {
      await AppStateRefresher.resetForLogout(
        ProviderScope.containerOf(context, listen: false),
      );
    }
    if (mounted) {
      setState(() => _currentEntryId = NavEntryIds.home);
      Navigator.of(context).popUntil((route) => route.isFirst);
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    if (mounted && action == _AuthErrorDialogAction.clearData) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const DataManagementPage()));
    }
  }

  String _buildAuthErrorDialogMessage(
    String message,
    PassiveLogoutAdvice advice,
  ) {
    final buffer = StringBuffer(message);

    if (advice.mentionCookieRepair) {
      buffer.write('\n\n${S.current.auth_cookieRepairLogoutHint}');
    }

    if (advice.suggestClearData) {
      buffer.write('\n\n${S.current.auth_frequentLogoutClearDataHint}');
    }

    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    // 监听当前用户状态
    final currentUserAsync = ref.watch(currentUserProvider);
    final user = currentUserAsync.value;

    // 从偏好读取底栏布局，按注册表解析为 entry 列表（含所有 kind）
    final bottomNavIds = ref.watch(
      preferencesProvider.select((p) => p.bottomNavIds),
    );
    final entries = _resolveEntries(bottomNavIds, user);
    _lastResolvedEntries = entries;

    // page kind 的子集用于 IndexedStack
    final pageEntries = entries
        .where((e) => e.kind == NavEntryKind.page)
        .toList();

    // 按稳定 id 定位当前页；当前页被过滤（如退出登录后 requiresLogin
    // entry 消失）时回退到第一个 page，下标绝不残留旧语义
    var safePageIndex = pageEntries.indexWhere((e) => e.id == _currentEntryId);
    if (safePageIndex < 0) safePageIndex = 0;

    // 底栏 selectedIndex 是当前激活 page 在 entries（含 panel/action）中的位置
    final selectedBottomIndex = pageEntries.isEmpty
        ? 0
        : entries.indexOf(pageEntries[safePageIndex]);

    // 监听外部 tab 切换信号（快捷键触发），index 维度是 pageEntries
    ref.listen(switchTabProvider, (_, index) {
      if (index < 0 || index >= pageEntries.length) return;
      final id = pageEntries[index].id;
      if (id == _currentEntryId) return;
      ref.read(barVisibilityProvider.notifier).state = 1.0;
      setState(() => _currentEntryId = id);
    });

    // 通知、深链等外部入口按稳定 id 切换工作区，避免用户重排底栏后
    // 数字下标指向错误页面。
    ref.listen(navDestinationRequestProvider, (_, request) {
      if (request == null) return;
      final index = pageEntries.indexWhere(
        (entry) => entry.id == request.targetId,
      );
      if (index < 0 || request.targetId == _currentEntryId) return;
      ref.read(barVisibilityProvider.notifier).state = 1.0;
      setState(() => _currentEntryId = request.targetId);
    });

    final destinations = [
      for (final e in entries)
        AdaptiveDestination(
          id: e.id,
          icon: e.customIconBuilder != null
              ? e.customIconBuilder!(context, ref)
              : Icon(e.iconData),
          selectedIcon: e.customSelectedIconBuilder != null
              ? e.customSelectedIconBuilder!(context, ref)
              // 同一 IconData 用 fill:1 表达选中态，避免不同字形错位
              : Icon(e.selectedIconData, fill: 1),
          label: e.label(context),
        ),
    ];

    // 通知入口在桌面侧栏可能出现两处：
    // 1) 用户把 notifications 加入底栏布局，作为 NavEntry 渲染
    // 2) railBottomLeading 默认提供的 NotificationIconButton
    // 已在底栏配置时不再额外渲染，避免重复。
    final hasNotificationEntry = entries.any(
      (e) => e.id == NavEntryIds.notifications,
    );
    // 深层平行视界隐藏 Rail 的旧联动已砍:抽掉 72px 侧栏 = 内容区
    // 瞬间变宽,这发生在布局动画体系之外,快照底板盖不住,是压/退栈
    // "必闪"的外部几何跳变源(还会触发编排撞帧取消)。Rail 恒定,
    // 栏宽恒定,层间过渡才是纯内容平移(iPad 三栏同款前提)。
    const hideNavigationRail = false;
    final exitOnSingleBack = ref.watch(
      preferencesProvider.select((preferences) => preferences.exitOnSingleBack),
    );
    final requireDoubleBackToExit = Platform.isAndroid && !exitOnSingleBack;
    final routeCanPopInternally = ModalRoute.canPopOf(context) ?? false;

    // 首页的 FAB 由 TopicsScreen 内部处理，避免切换时闪烁。
    // 单次退出模式允许系统处理 bubble 以支持预测式退出；双击退出模式
    // 则拦截根路由的第一次返回。面板在两种模式下都拥有更高优先级。
    Widget page = ValueListenableBuilder<bool>(
      valueListenable: NotificationQuickPanel.visible,
      builder: (context, notificationPanelVisible, _) =>
          ValueListenableBuilder<bool>(
        // 平行视界投影态(窄屏详情全宽盖在 tab 体内)开着时返回由
        // PaneProjectionBackScope 消费,根层完全让位:不弹退出 toast。
        valueListenable: PaneProjectionBackScope.hasActiveProjection,
        builder: (context, paneProjectionOpen, _) => PopScope(
          canPop:
              routeCanPopInternally ||
              (!notificationPanelVisible &&
                  !paneProjectionOpen &&
                  !requireDoubleBackToExit),
          onPopInvokedWithResult: (bool didPop, dynamic result) {
            if (didPop) return;
            // 分类侧栏通过 LocalHistoryEntry 消费返回；这里保留兜底，覆盖
            // 抽屉正在收尾动画等 LocalHistory 尚未同步的短暂状态。
            if (CategoryDrawerHost.isOpen) {
              CategoryDrawerHost.close();
              return;
            }
            if (NotificationQuickPanel.isVisible) {
              NotificationQuickPanel.dismiss();
              return;
            }
            // 投影态:PaneProjectionBackScope 的 PopEntry 自己消费本次
            // 返回(关投影层),根层不做双击退出。
            if (PaneProjectionBackScope.hasActiveProjection.value) {
              return;
            }
            if (requireDoubleBackToExit) {
              if (_backExitGuard.shouldExit()) {
                SystemNavigator.pop();
              } else {
                ToastService.showInfo(S.current.toast_pressAgainToExit);
              }
            }
          },
          child: AdaptiveScaffold(
            selectedIndex: selectedBottomIndex,
            onDestinationSelected: _onDestinationSelected,
            destinations: destinations,
            railBottomLeading: (user != null && !hasNotificationEntry)
                ? const NotificationIconButton()
                : null,
            hideNavigationRail: hideNavigationRail,
            // 投影态底栏隐藏:详情全宽盖在 tab 体内,底栏还留着会像
            // "详情页悬在 tab 骨架上";合成路由时代盖住一切,投影态
            // 用显式谓词达成同样观感。
            hideBottomNavigation: paneProjectionOpen,
            body: IndexedStack(
              index: safePageIndex,
              children: [
                for (int i = 0; i < pageEntries.length; i++)
                  KeyedSubtree(
                    key: ValueKey('nav-entry-${pageEntries[i].id}'),
                    child: TickerMode(
                      enabled: safePageIndex == i,
                      child: ExcludeFocus(
                        excluding: safePageIndex != i,
                        child: pageEntries[i].pageBuilder!(
                          context,
                          safePageIndex == i,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // 桌面端需要 Focus 以接收全局快捷键
    if (PlatformUtils.isDesktop) {
      page = Focus(autofocus: true, child: page);
    }

    return page;
  }

  /// 按偏好的顺序解析 entry 列表（含所有 kind）
  ///
  /// - 移除注册表里不存在的 id
  /// - 未登录时过滤掉 requiresLogin 的 entry
  /// - 去重
  /// - 补齐 locked entry（防御；正常情况编辑器已保证包含）
  List<NavEntry> _resolveEntries(List<String> ids, User? user) {
    final all = NavEntryRegistry.buildAll();
    final byId = {for (final e in all) e.id: e};
    final resolved = <NavEntry>[];
    final seen = <String>{};

    for (final id in ids) {
      final e = byId[id];
      if (e == null) continue;
      if (e.requiresLogin && user == null) continue;
      if (seen.contains(id)) continue;
      resolved.add(e);
      seen.add(id);
    }

    // 补 locked（防御偏好被外部写坏）
    for (final id in NavEntryRegistry.lockedIds()) {
      if (seen.contains(id)) continue;
      final e = byId[id];
      if (e == null) continue;
      if (e.requiresLogin && user == null) continue;
      resolved.add(e);
      seen.add(id);
    }

    return resolved;
  }
}
