import 'dart:async';
import 'dart:io';

import 'package:catcher_2/catcher_2.dart';
import 'package:chinese_font_library/chinese_font_library.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'pages/topics_page.dart';
import 'pages/data_management_page.dart';
import 'providers/discourse_providers.dart';
import 'providers/locale_provider.dart';
import 'widgets/ai/builtin_presets_factory.dart';
import 'providers/message_bus_providers.dart';
import 'services/auth_issue_notice_service.dart';
import 'providers/app_state_refresher.dart';
import 'services/highlighter_service.dart';
import 'widgets/common/notification_icon_button.dart';
import 'widgets/common/clipboard_topic_link_snack_content.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'services/network/cookie/csrf_token_service.dart';
import 'services/network/cookie/cookie_devtools_extension.dart';
import 'services/network/cookie/cookie_jar_service.dart';
import 'services/network/cookie/cookie_store_observer.dart';
import 'services/network/adapters/cronet_fallback_service.dart';
import 'services/local_notification_service.dart';
import 'services/data_management/cache_size_service.dart';
import 'services/discourse_cache_manager.dart';
import 'services/toast_service.dart';
import 'widgets/common/loading_spinner.dart';
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
import 'services/clipboard_topic_link_service.dart';
import 'services/deep_link_service.dart';
import 'services/background/background_notification_service.dart';
import 'services/message_bus_service.dart';
import 'services/connectivity_service.dart';
import 'services/log/json_file_handler.dart';
import 'services/log/filtered_catcher_logger.dart';
import 'services/log/log_writer.dart';
import 'services/download_service.dart';
import 'services/migration_service.dart';
import 'services/navigation/app_route_observer.dart';
import 'services/window_state_service.dart';
import 'services/webview_settings.dart';
import 'services/windows_webview_environment_service.dart';
import 'services/user_presence_service.dart';
import 'models/user.dart';
import 'constants.dart';
import 'providers/connectivity_provider.dart';
import 'utils/dialog_utils.dart';
import 'utils/time_utils.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_model_manager/ai_model_manager.dart';
import 'services/app_logger.dart';
import 'services/network/adapters/platform_adapter.dart';
import 'providers/preferences_provider.dart';
import 'providers/theme_provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'widgets/preheat_gate.dart';
import 'widgets/onboarding_gate.dart';
import 'widgets/layout/adaptive_scaffold.dart';
import 'widgets/layout/adaptive_navigation.dart';
import 'widgets/notification/notification_quick_panel.dart';
import 'widgets/read_later/read_later_bubble.dart';
import 'navigation/nav_action_bus.dart';
import 'navigation/nav_entry.dart';
import 'navigation/nav_entry_registry.dart';
import 'providers/read_later_provider.dart';
import 'providers/shortcut_provider.dart';
import 'widgets/keyboard_shortcut_handler.dart';
import 'utils/platform_utils.dart';

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
  WidgetsFlutterBinding.ensureInitialized();

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
    if (Platform.isWindows)
      WindowsWebViewEnvironmentService.instance.initialize(),
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

  // v0.4.0: 注册 Cookie 引擎 DevTools service extensions (仅 debug/profile 模式)
  // 设计依据: docs/cookie-sync-design-v0.4.0.md §11.4
  CookieDevtoolsExtension.instance.register();

  // v0.4.0 Phase B: 启动 WV cookie store 外部变化观察
  // Apple 平台依赖 native WKHTTPCookieStoreObserver 自动触发,
  // Android 由 WV onLoadStop 等 hook 主动调 notifyExternalChange()。
  CookieStoreObserver.instance.attach();

  // 桌面平台：恢复窗口状态后再显示，避免默认位置闪烁
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
      await WindowStateService.instance.attach(prefs);
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
  // 启动期浏览器信任准备由 BrowserTrustCoordinator 统一编排。
  BrowserTrustCoordinator.instance.prepareStartup(reason: 'startup');
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

  await NetworkSettingsService.instance.initialize(prefs);
  VpnAutoToggleService.instance.initialize(prefs);
  try {
    final initialConnectivity =
        await ConnectivityService.safeCheckConnectivity();
    await VpnAutoToggleService.instance.syncInitialState(initialConnectivity);
  } catch (e) {
    debugPrint('[Main] 初始 VPN 状态同步失败: $e');
  }

  // 初始化下载服务（依赖网络栈已就绪）
  DownloadService().initialize();

  // 冷启动自动清除图片缓存（如果用户开启了该选项）
  if (prefs.getBool('pref_clear_cache_on_exit') == true) {
    Future.wait([
      DiscourseCacheManager().emptyCache(),
      EmojiCacheManager().emptyCache(),
      ExternalImageCacheManager().emptyCache(),
    ]).then((_) => CacheSizeService.deleteImageCacheDirs()).ignore();
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

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    ref.listen<Locale?>(localeProvider, (_, next) {
      unawaited(_syncSlangLocale(next));
    });

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // 把系统动态色原始 primary 存到 ThemeState 中
        final rawDynamicPrimary = lightDynamic?.primary;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(themeProvider.notifier).setDynamicPrimary(rawDynamicPrimary);
        });

        ColorScheme lightScheme;
        ColorScheme darkScheme;

        if (themeState.useDynamicColor &&
            lightDynamic != null &&
            darkDynamic != null) {
          // Optimization: Use standard ColorScheme.fromSeed with the dynamic primary color
          // This ensures better contrast and consistency than using the raw OEM scheme
          lightScheme = ColorScheme.fromSeed(
            seedColor: lightDynamic.primary,
            brightness: Brightness.light,
            dynamicSchemeVariant: themeState.schemeVariant,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: darkDynamic.primary,
            brightness: Brightness.dark,
            dynamicSchemeVariant: themeState.schemeVariant,
          );
        } else {
          lightScheme = ColorScheme.fromSeed(
            seedColor: themeState.seedColor,
            brightness: Brightness.light,
            dynamicSchemeVariant: themeState.schemeVariant,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: themeState.seedColor,
            brightness: Brightness.dark,
            dynamicSchemeVariant: themeState.schemeVariant,
          );
        }

        return TranslationProvider(
          child: Builder(
            builder: (context) => MaterialApp(
              navigatorKey: navigatorKey,
              navigatorObservers: [appRouteObserver],
              title: 'FluxDO',
              locale: TranslationProvider.of(context).flutterLocale,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocaleUtils.supportedLocales,
              themeMode: themeState.mode,
              // 仅注入 fontFamilyFallback，不替换 textTheme，避免覆盖 Android OEM
              // 系统字体（chinese_font_library 自带的 ThemeData.useSystemChineseFont
              // 会强制改为 Roboto，导致字体显得比之前粗）。
              theme: _withChineseFallback(
                ThemeData(
                  colorScheme: lightScheme,
                  useMaterial3: true,
                  fontFamily: themeState.fontFamilyName,
                  cardTheme: CardThemeData(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    color: lightScheme.surfaceContainerLow,
                    margin: EdgeInsets.zero,
                  ),
                  popupMenuTheme: PopupMenuThemeData(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 3,
                    color: lightScheme.surfaceContainerLow,
                    surfaceTintColor: Colors.transparent,
                    menuPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              darkTheme: _withChineseFallback(
                ThemeData(
                  colorScheme: darkScheme,
                  useMaterial3: true,
                  fontFamily: themeState.fontFamilyName,
                  cardTheme: CardThemeData(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    color: darkScheme.surfaceContainerLow,
                    margin: EdgeInsets.zero,
                  ),
                  popupMenuTheme: PopupMenuThemeData(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 3,
                    color: darkScheme.surfaceContainerLow,
                    surfaceTintColor: Colors.transparent,
                    menuPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
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
                    effect: Platform.isMacOS
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
                    children: [child!, const ReadLaterBubble()],
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

                // 桌面端：全局键盘快捷键（HardwareKeyboard）
                if (PlatformUtils.isDesktop) {
                  result = KeyboardShortcutHandler(
                    navigatorKey: navigatorKey,
                    child: result,
                  );
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
  int _currentIndex = 0;
  ProviderSubscription<AsyncValue<String>>? _authErrorSub;
  ProviderSubscription<AsyncValue<void>>? _authStateSub;
  ProviderSubscription<AsyncValue<User?>>? _currentUserSub;
  ProviderSubscription<void>? _messageBusSub;
  ProviderSubscription<void>? _notificationChannelSub;
  ProviderSubscription<void>? _notificationAlertChannelSub;
  ProviderSubscription<AsyncValue<bool>>? _connectivitySub;
  bool _messageBusInitialized = false;
  int? _lastTappedIndex;
  DateTime? _lastTapTime;
  Timer? _pendingSingleTap;
  List<NavEntry> _lastResolvedEntries = const [];
  Timer? _resumeDebounceTimer;
  DateTime? _lastBackPressTime;

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

    _authStateSub = ref.listenManual<AsyncValue<void>>(authStateProvider, (
      _,
      next,
    ) {
      next.whenData((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          AppStateRefresher.refreshAll(
            ProviderScope.containerOf(context, listen: false),
          );
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
        });
      } else if (user == null) {
        _messageBusInitialized = false;
        _messageBusSub?.close();
        _messageBusSub = null;
        _notificationChannelSub?.close();
        _notificationChannelSub = null;
        _notificationAlertChannelSub?.close();
        _notificationAlertChannelSub = null;
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

    // 非 page kind：直接触发对应回调，不改 _currentIndex
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

    // page kind
    final newPageIndex = _pageIndexOfBottom(index);
    if (newPageIndex < 0) return;

    final now = DateTime.now();

    // 切换 tab：只记录时间戳，不走手势分流
    if (newPageIndex != _currentIndex) {
      _cancelPendingSingleTap();
      _lastTappedIndex = index;
      _lastTapTime = now;
      ref.read(barVisibilityProvider.notifier).state = 1.0;
      setState(() => _currentIndex = newPageIndex);
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
    final prefs = ref.read(sharedPreferencesProvider);
    final clipboardTopicLinkService = ClipboardTopicLinkService.instance;
    final candidate = await clipboardTopicLinkService.checkClipboard(
      enabled: ref.read(preferencesProvider).clipboardTopicLinkDetection,
      lastPromptedHash: prefs.getInt(
        ClipboardTopicLinkService.lastPromptedHashPrefsKey,
      ),
    );
    if (!mounted || candidate == null) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    var promptHandled = false;
    void markPromptedOnce() {
      if (promptHandled) return;
      promptHandled = true;
      unawaited(
        clipboardTopicLinkService.markPrompted(candidate, prefs: prefs),
      );
    }

    messenger.hideCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        content: ClipboardTopicLinkSnackContent(
          message: context.l10n.preferences_clipboardTopicLink_detected,
          actionLabel: context.l10n.preferences_clipboardTopicLink_open,
          onOpen: () {
            markPromptedOnce();
            messenger.hideCurrentSnackBar();
            DeepLinkService.instance.handleUri(candidate.uri);
          },
          onDismiss: () {
            markPromptedOnce();
            messenger.hideCurrentSnackBar();
          },
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        duration: const Duration(seconds: 8),
        elevation: 0,
        padding: EdgeInsets.zero,
        margin: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 16 + MediaQuery.paddingOf(context).bottom,
        ),
      ),
    );
    unawaited(controller.closed.then((_) => markPromptedOnce()));
  }

  /// App 进入后台：先启动前台服务保活，再切换到只轮询通知频道
  Future<void> _enterBackground() async {
    // 清除 Flutter 图片内存缓存，降低后台内存占用
    PaintingBinding.instance.imageCache.clear();

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
      setState(() => _currentIndex = 0);
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

    // _currentIndex 维度是 pageEntries；越界时 clamp
    final safePageIndex = pageEntries.isEmpty
        ? 0
        : _currentIndex.clamp(0, pageEntries.length - 1);

    // 底栏 selectedIndex 是当前激活 page 在 entries（含 panel/action）中的位置
    final selectedBottomIndex = pageEntries.isEmpty
        ? 0
        : entries.indexOf(pageEntries[safePageIndex]);

    // 监听外部 tab 切换信号（快捷键触发），index 维度是 pageEntries
    ref.listen(switchTabProvider, (_, index) {
      if (index >= 0 && index < pageEntries.length && index != _currentIndex) {
        ref.read(barVisibilityProvider.notifier).state = 1.0;
        setState(() => _currentIndex = index);
      }
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
              : Icon(e.selectedIconData),
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

    // 首页的 FAB 由 TopicsScreen 内部处理，避免切换时闪烁
    Widget page = PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        if (NotificationQuickPanel.isVisible) {
          NotificationQuickPanel.dismiss();
          return;
        }
        final now = DateTime.now();
        if (_lastBackPressTime != null &&
            now.difference(_lastBackPressTime!).inMilliseconds < 2000) {
          SystemNavigator.pop();
        } else {
          _lastBackPressTime = now;
          ToastService.showInfo(S.current.toast_pressAgainToExit);
        }
      },
      child: AdaptiveScaffold(
        selectedIndex: selectedBottomIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: destinations,
        railBottomLeading: (user != null && !hasNotificationEntry)
            ? const NotificationIconButton()
            : null,
        body: IndexedStack(
          index: safePageIndex,
          children: [
            for (int i = 0; i < pageEntries.length; i++)
              KeyedSubtree(
                key: ValueKey('nav-entry-${pageEntries[i].id}'),
                child: pageEntries[i].pageBuilder!(context, safePageIndex == i),
              ),
          ],
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
